local format = require("email.format")
local highlight = require("email.ui.highlight")
local layout = require("email.ui.layout")
local state = require("email.state")

local M = {}

function M.same(a, b)
  return a ~= nil and b ~= nil and a.smart == b.smart and a.account == b.account and a.index == b.index
end

local function is_active(folder)
  return M.same(state.folder, folder)
end

function M.label(folder)
  if folder.smart then
    return "Smart · " .. folder.name
  end
  return state.config.accounts[folder.account].name .. " · " .. folder.name
end

function M.unread_of(folder)
  local group = folder.smart and state.unread.smart or state.unread[folder.account]
  return (group or {})[folder.index] or 0
end

function M.folders()
  local out = {}
  for si, search in ipairs(state.config.searches) do
    out[#out + 1] = { smart = true, index = si, name = search.name, query = search.query }
  end
  for ai, account in ipairs(state.config.accounts) do
    for fi, folder in ipairs(account.folders) do
      out[#out + 1] = { account = ai, index = fi, name = folder.name, query = folder.query }
    end
  end
  return out
end

local function icon_line(indent, icon, label)
  local prefix = indent .. icon .. " "
  return prefix, prefix .. label
end

function M.render()
  local buf = state.buf.sidebar
  if not buf then
    return
  end
  local config = state.config
  local width = config.sidebar_width
  local lines, highlights, rows, active_row = {}, {}, {}, nil
  local groups = {}
  if #config.searches > 0 then
    groups[#groups + 1] =
      { title = "Smart", icon = config.folder_icons.search, smart = true, folders = config.searches }
  end
  for ai, account in ipairs(config.accounts) do
    groups[#groups + 1] =
      { title = account.name, icon = config.folder_icons.account, account = ai, folders = account.folders }
  end
  for gi, group in ipairs(groups) do
    if gi > 1 then
      lines[#lines + 1] = ""
    end
    local prefix, line = icon_line(" ", group.icon, group.title)
    lines[#lines + 1] = line
    highlights[#lines] = { { 0, #prefix, "EmailAccountIcon" }, { #prefix, #line, "EmailAccount" } }
    for fi, folder in ipairs(group.folders) do
      local entry =
        { smart = group.smart, account = group.account, index = fi, name = folder.name, query = folder.query }
      local unread = M.unread_of(entry)
      local count = unread > 0 and (tostring(unread) .. " ") or ""
      local active = is_active(entry)
      local folder_prefix, text = icon_line("   ", format.folder_icon(folder.name, config.folder_icons), folder.name)
      local label = format.fit(text, width - #count)
      lines[#lines + 1] = label .. count
      rows[#lines] = entry
      local hls = {
        { 0, #folder_prefix, active and "EmailFolderActive" or "EmailFolderIcon" },
        { #folder_prefix, #label, active and "EmailFolderActive" or "EmailFolder" },
      }
      if count ~= "" then
        hls[#hls + 1] = { #label, #label + #count, "EmailCount" }
      end
      highlights[#lines] = hls
      if active then
        active_row = #lines
      end
    end
  end
  if state.folder and state.folder.search then
    lines[#lines + 1] = ""
    local prefix, line = icon_line(" ", config.folder_icons.search, "Search")
    lines[#lines + 1] = line
    highlights[#lines] = { { 0, #prefix, "EmailAccountIcon" }, { #prefix, #line, "EmailAccount" } }
    lines[#lines + 1] = format.fit("   " .. state.folder.search, width)
    highlights[#lines] = { { 0, #lines[#lines], "EmailFolderActive" } }
    active_row = #lines
  end
  state.sidebar_rows = rows
  layout.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, highlight.ns, 0, -1)
  for row, hls in pairs(highlights) do
    highlight.apply(buf, row - 1, hls)
  end
  if active_row and state.win.sidebar and vim.api.nvim_win_is_valid(state.win.sidebar) then
    vim.api.nvim_win_set_cursor(state.win.sidebar, { active_row, 0 })
  end
end

function M.folder_at_cursor()
  local row = vim.api.nvim_win_get_cursor(state.win.sidebar)[1]
  return state.sidebar_rows[row]
end

return M
