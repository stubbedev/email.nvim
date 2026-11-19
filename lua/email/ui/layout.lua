local images = require("email.images")
local state = require("email.state")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local PLAIN_WINDOW = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  colorcolumn = "",
  spell = false,
  list = false,
}

local group = vim.api.nvim_create_augroup("email.nvim.layout", { clear = true })
local spinner_timer, spinner_frame, spinner_label
local bars = {}

local function full()
  return state.config.layout == "full"
end

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
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  return buf
end

local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

local function render_bar(name)
  local win, bar = state.win[name], bars[name]
  if not valid(win) or not bar then
    return
  end
  local title = bar.title and ("%#EmailWinbarTitle# " .. escape(bar.title) .. " ") or ""
  local status = table.concat(
    vim.tbl_filter(function(part)
      return part ~= nil and part ~= ""
    end, { bar.left, bar.right }),
    "  "
  )
  vim.wo[win].winbar = title .. "%#WinBar#%=" .. escape(status) .. " "
end

local function float_window(buf, enter, g, title)
  local config = win_config(g)
  config.border = state.config.border
  config.style = "minimal"
  config.title = " " .. title .. " "
  config.title_pos = "center"
  config.zindex = 45
  return vim.api.nvim_open_win(buf, enter, config)
end

local function plain(win)
  for option, value in pairs(PLAIN_WINDOW) do
    vim.wo[win][option] = value
  end
end

local function register(name, win, buf, title)
  state.win[name] = win
  state.buf[name] = buf
  if full() then
    bars[name] = { title = title }
    plain(win)
    render_bar(name)
  end
  return win
end

local function set_hidden(hidden)
  for _, name in ipairs({ "sidebar", "list" }) do
    if valid(state.win[name]) then
      vim.api.nvim_win_set_config(state.win[name], { hide = hidden })
    end
  end
end

function M.reader_width()
  if full() then
    return vim.o.columns
  end
  return geometry().reader.width
end

function M.is_open()
  return valid(state.win.list)
end

function M.set_title(name, title)
  if not valid(state.win[name]) then
    return
  end
  if full() then
    bars[name] = bars[name] or {}
    bars[name].title = title
    render_bar(name)
    return
  end
  vim.api.nvim_win_set_config(state.win[name], { title = " " .. title .. " ", title_pos = "center" })
end

function M.set_status(name, left, right)
  local win = state.win[name]
  if not valid(win) then
    return
  end
  if full() then
    bars[name] = bars[name] or {}
    bars[name].left, bars[name].right = left, right
    render_bar(name)
    return
  end
  if left and right then
    local width = vim.api.nvim_win_get_width(win)
    local fill = math.max(0, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
    vim.api.nvim_win_set_config(win, {
      footer = { { left, "FloatFooter" }, { string.rep("─", fill), "FloatBorder" }, { right, "FloatFooter" } },
      footer_pos = "left",
    })
    return
  end
  vim.api.nvim_win_set_config(win, { footer = left or right or "", footer_pos = "center" })
end

function M.resize()
  if not M.is_open() or full() then
    return
  end
  local g = geometry()
  for _, name in ipairs({ "sidebar", "list", "reader" }) do
    if valid(state.win[name]) then
      vim.api.nvim_win_set_config(state.win[name], win_config(g[name]))
    end
  end
end

local function close_window(win)
  if not valid(win) then
    return
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local last_tab = #vim.api.nvim_list_tabpages() == 1
  local last_in_tab = #vim.api.nvim_tabpage_list_wins(tab) == 1
  if full() and last_tab and last_in_tab then
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
    vim.wo[win].winbar = ""
    return
  end
  vim.api.nvim_win_close(win, true)
end

local function wipe(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

function M.close()
  if state.closing then
    return
  end
  state.closing = true
  images.clear()
  for _, name in ipairs({ "reader", "sidebar", "list" }) do
    close_window(state.win[name])
  end
  for _, name in ipairs({ "reader", "sidebar", "list" }) do
    wipe(state.buf[name])
  end
  state.win, state.buf, state.reading, state.current = {}, {}, false, nil
  bars = {}
  vim.api.nvim_clear_autocmds({ group = group })
  state.closing = false
end

local function watch()
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

local function empty_tab()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if #wins ~= 1 then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(wins[1])
  return vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) == ""
    and not vim.bo[buf].modified
    and vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

function M.open()
  local sidebar, list = scratch("email-sidebar"), scratch("email-list")
  if full() then
    if not empty_tab() then
      vim.cmd.tabnew()
    end
    local win, placeholder = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(win, list)
    wipe(placeholder)
    register("list", win, list, "Emails")
    local side =
      vim.api.nvim_open_win(sidebar, false, { split = "left", win = win, width = state.config.sidebar_width })
    register("sidebar", side, sidebar, "Folders")
    vim.wo[side].winfixwidth = true
  else
    local g = geometry()
    register("sidebar", float_window(sidebar, false, g.sidebar, "Folders"), sidebar)
    register("list", float_window(list, true, g.list, "Emails"), list)
  end
  for _, name in ipairs({ "sidebar", "list" }) do
    vim.wo[state.win[name]].cursorline = true
    vim.wo[state.win[name]].wrap = false
  end
  watch()
end

function M.open_reader()
  if valid(state.win.reader) then
    return state.buf.reader
  end
  state.reading = true
  local buf = scratch("email-message")
  local win
  if full() then
    vim.cmd.tabnew()
    win = vim.api.nvim_get_current_win()
    local placeholder = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(win, buf)
    wipe(placeholder)
  else
    win = float_window(buf, true, geometry().reader, "Email")
  end
  register("reader", win, buf, "Email")
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  if not full() then
    set_hidden(true)
  end
  return buf
end

function M.close_reader()
  images.clear()
  local buf = state.buf.reader
  if valid(state.win.reader) then
    state.closing = true
    close_window(state.win.reader)
    state.closing = false
  end
  wipe(buf)
  bars.reader = nil
  state.win.reader, state.buf.reader, state.reading, state.current = nil, nil, false, nil
  if not full() then
    set_hidden(false)
    M.resize()
  end
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
  M.set_status(status_window(), nil, " " .. SPINNER[spinner_frame] .. " " .. spinner_label .. " ")
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
  M.set_status("sidebar", nil, nil)
  if state.reading then
    M.set_status("reader", nil, state.reader_footer)
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
