local addresses = require("email.addresses")
local async = require("email.async")
local format = require("email.format")

local M = {}

local HEADERS = { "From", "To", "Cc", "Bcc", "Reply-To", "Subject" }
local OPTIONAL = { Bcc = true, ["Reply-To"] = true }
local CANONICAL = { attach = "Attach" }
for _, name in ipairs(HEADERS) do
  CANONICAL[name:lower()] = name
end

local counter = 0

function M.lines(draft)
  local lines = {}
  for _, name in ipairs(HEADERS) do
    local value = draft.headers[name] or ""
    if not OPTIONAL[name] or value ~= "" then
      lines[#lines + 1] = name .. ": " .. value
    end
  end
  for _, path in ipairs(draft.attach or {}) do
    lines[#lines + 1] = "Attach: " .. path
  end
  lines[#lines + 1] = ""
  vim.list_extend(lines, draft.body or {})
  return lines
end

function M.parse(lines)
  local headers, attach, last, i = {}, {}, nil, 1
  while i <= #lines and lines[i] ~= "" do
    local line = lines[i]
    local name, value = line:match("^([%w-]+):%s*(.-)%s*$")
    if name then
      local canonical = CANONICAL[name:lower()] or error(("line %d: unknown header %q"):format(i, name), 0)
      if canonical == "Attach" then
        if value ~= "" then
          attach[#attach + 1] = vim.fs.normalize(value)
        end
        last = nil
      else
        headers[canonical] = value
        last = canonical
      end
    elseif last and line:match("^%s") then
      headers[last] = headers[last] .. " " .. vim.trim(line)
    else
      error(("line %d is not a header: %s"):format(i, line), 0)
    end
    i = i + 1
  end
  return { headers = headers, attach = attach, body = table.concat(lines, "\n", i + 1) }
end

local function show(session)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor((vim.o.lines - vim.o.cmdheight) * 0.8)
  local keymaps = session.keymaps
  session.win = vim.api.nvim_open_win(session.buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - vim.o.cmdheight - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = session.border,
    title = " Compose ",
    title_pos = "center",
    footer = (" %s%s send · %s attach · :w save draft · %s discard "):format(
      session.draft.calendar and ("calendar reply: " .. session.draft.calendar.label .. " · ") or "",
      keymaps.send and format.keys(keymaps.send) or "-",
      keymaps.attach and format.keys(keymaps.attach) or "-",
      keymaps.discard and format.keys(keymaps.discard) or "-"
    ),
    footer_pos = "center",
    zindex = 60,
  })
  vim.wo[session.win].wrap = true
  vim.wo[session.win].linebreak = true
end

function M.add_attachments(buf, paths)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blank = #lines + 1
  for i, line in ipairs(lines) do
    if line == "" then
      blank = i
      break
    end
  end
  local entries = {}
  for i, path in ipairs(paths) do
    local full = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    if not vim.uv.fs_stat(full) then
      error(("cannot attach %s: no such file"):format(full), 0)
    end
    entries[i] = "Attach: " .. full
  end
  vim.api.nvim_buf_set_lines(buf, blank - 1, blank - 1, false, entries)
end

function M.open(draft, handlers, keymaps, border)
  counter = counter + 1
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, ("email://compose/%d"):format(counter))
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(draft))
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "mail"
  vim.bo[buf].omnifunc = "v:lua.require'email.addresses'.omnifunc"
  vim.b[buf].email_composer = true
  addresses.refresh()

  local session = {
    buf = buf,
    draft = draft,
    keymaps = keymaps,
    border = border,
    lock = async.mutex(),
    closed = false,
  }
  function session.current()
    return M.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end
  function session.hide()
    vim.bo[buf].bufhidden = "hide"
    if session.win and vim.api.nvim_win_is_valid(session.win) then
      vim.api.nvim_win_close(session.win, true)
    end
  end
  function session.show()
    vim.bo[buf].bufhidden = "wipe"
    show(session)
  end
  function session.close()
    session.closed = true
    vim.bo[buf].modified = false
    vim.bo[buf].bufhidden = "wipe"
    if session.win and vim.api.nvim_win_is_valid(session.win) then
      vim.api.nvim_win_close(session.win, true)
    elseif vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  show(session)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      session.closed = true
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      handlers.save(session)
    end,
  })
  local actions = {
    send = function()
      handlers.send(session)
    end,
    attach = function()
      handlers.attach(session)
    end,
    discard = function()
      if vim.fn.confirm("Discard this message?", "&Discard\n&Keep", 2) == 1 then
        session.close()
      end
    end,
  }
  for action, lhs in pairs(keymaps) do
    if lhs then
      for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
        vim.keymap.set("n", key, actions[action], { buffer = buf, desc = "email: " .. action })
      end
    end
  end

  local first_empty = vim.fn.search([[^\(To\|Subject\):\s*$]], "nw")
  if first_empty > 0 then
    vim.api.nvim_win_set_cursor(session.win, { first_empty, 0 })
    vim.cmd("startinsert!")
  end
  return session
end

return M
