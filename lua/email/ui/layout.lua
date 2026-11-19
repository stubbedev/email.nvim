local images = require("email.images")
local state = require("email.state")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local group = vim.api.nvim_create_augroup("email.nvim.layout", { clear = true })
local spinner_timer, spinner_frame, spinner_label

local function geometry()
  local cfg = state.config
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local width = math.floor(columns * cfg.width)
  local height = math.floor(lines * cfg.height)
  local row = math.floor((lines - height) / 2)
  local col = math.floor((columns - width) / 2)
  local main_col = col + cfg.sidebar_width + 2
  local main_width = width - cfg.sidebar_width - 4
  return {
    sidebar = { row = row, col = col, width = cfg.sidebar_width, height = height - 2 },
    list = { row = row, col = main_col, width = main_width, height = height - 2 },
    reader = { row = row, col = col, width = width - 2, height = height - 2 },
  }
end

local function win_config(g)
  return {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
  }
end

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function scratch(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  return buf
end

local function open_window(name, buf, enter, g, title)
  local config = win_config(g)
  config.border = state.config.border
  config.style = "minimal"
  config.title = " " .. title .. " "
  config.title_pos = "center"
  config.zindex = 45
  local win = vim.api.nvim_open_win(buf, enter, config)
  state.win[name] = win
  state.buf[name] = buf
  return win
end

local function set_hidden(hidden)
  for _, name in ipairs({ "sidebar", "list" }) do
    if valid(state.win[name]) then
      vim.api.nvim_win_set_config(state.win[name], { hide = hidden })
    end
  end
end

function M.is_open()
  return valid(state.win.list)
end

function M.set_title(name, title)
  if valid(state.win[name]) then
    vim.api.nvim_win_set_config(state.win[name], { title = " " .. title .. " ", title_pos = "center" })
  end
end

function M.set_footer(name, footer, pos)
  if valid(state.win[name]) then
    vim.api.nvim_win_set_config(state.win[name], { footer = footer, footer_pos = pos or "center" })
  end
end

function M.resize()
  if not M.is_open() then
    return
  end
  local g = geometry()
  for _, name in ipairs({ "sidebar", "list", "reader" }) do
    if valid(state.win[name]) then
      vim.api.nvim_win_set_config(state.win[name], win_config(g[name]))
    end
  end
end

function M.close()
  if state.closing then
    return
  end
  state.closing = true
  images.clear()
  for _, name in ipairs({ "reader", "list", "sidebar" }) do
    if valid(state.win[name]) then
      vim.api.nvim_win_close(state.win[name], true)
    end
  end
  state.win, state.buf, state.reading, state.current = {}, {}, false, nil
  vim.api.nvim_clear_autocmds({ group = group })
  state.closing = false
end

function M.open()
  local g = geometry()
  open_window("sidebar", scratch("email-sidebar"), false, g.sidebar, "Folders")
  open_window("list", scratch("email-list"), true, g.list, "Emails")
  for _, name in ipairs({ "sidebar", "list" }) do
    vim.wo[state.win[name]].cursorline = true
    vim.wo[state.win[name]].wrap = false
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if state.closing then
        return
      end
      if closed == state.win.reader then
        vim.schedule(M.close_reader)
      elseif closed == state.win.list or closed == state.win.sidebar then
        vim.schedule(M.close)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = M.resize })
end

function M.open_reader()
  if valid(state.win.reader) then
    return state.buf.reader
  end
  state.reading = true
  local win = open_window("reader", scratch("email-message"), true, geometry().reader, "Email")
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nc"
  set_hidden(true)
  return state.buf.reader
end

function M.close_reader()
  images.clear()
  if valid(state.win.reader) then
    state.closing = true
    vim.api.nvim_win_close(state.win.reader, true)
    state.closing = false
  end
  state.win.reader, state.buf.reader, state.reading, state.current = nil, nil, false, nil
  set_hidden(false)
  M.resize()
  M.focus("list")
end

function M.focus(name)
  if valid(state.win[name]) then
    vim.api.nvim_set_current_win(state.win[name])
  end
end

local function status_window()
  return state.reading and "reader" or "sidebar"
end

local function draw_spinner()
  spinner_frame = spinner_frame % #SPINNER + 1
  M.set_footer(status_window(), " " .. SPINNER[spinner_frame] .. " " .. spinner_label .. " ")
end

function M.busy(label)
  state.busy = state.busy + 1
  spinner_label = label
  if spinner_timer then
    return
  end
  spinner_frame = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(0, 80, vim.schedule_wrap(draw_spinner))
  spinner_timer = timer
end

function M.idle()
  state.busy = math.max(0, state.busy - 1)
  if state.busy > 0 or not spinner_timer then
    return
  end
  spinner_timer:stop()
  spinner_timer:close()
  spinner_timer = nil
  M.set_footer("sidebar", "")
  if state.reading then
    M.set_footer("reader", state.reader_footer or "", "center")
  end
end

function M.with_busy(label, fn)
  M.busy(label)
  local ok, err = pcall(fn)
  M.idle()
  if not ok then
    error(err, 0)
  end
end

function M.set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

return M
