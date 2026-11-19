local format = require("email.format")
local highlight = require("email.ui.highlight")
local layout = require("email.ui.layout")
local state = require("email.state")

local M = {}

local function is_active(folder)
  return state.folder and state.folder.account == folder.account and state.folder.index == folder.index
end

function M.folders()
  local out = {}
  for ai, account in ipairs(state.config.accounts) do
    for fi, folder in ipairs(account.folders) do
      out[#out + 1] = { account = ai, index = fi, name = folder.name, query = folder.query }
    end
  end
  return out
end

function M.render()
  local buf = state.buf.sidebar
  if not buf then
    return
  end
  local width = state.config.sidebar_width
  local lines, highlights, rows, active_row = {}, {}, {}, nil
  for ai, account in ipairs(state.config.accounts) do
    if ai > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = " " .. account.name
    highlights[#lines] = { { 0, #lines[#lines], "EmailAccount" } }
    for fi, folder in ipairs(account.folders) do
      local unread = (state.unread[ai] or {})[fi] or 0
      local count = unread > 0 and (tostring(unread) .. " ") or ""
      local entry = { account = ai, index = fi, name = folder.name, query = folder.query }
      local label = format.fit("   " .. folder.name, width - #count)
      lines[#lines + 1] = label .. count
      rows[#lines] = entry
      local hls = { { 0, #label, is_active(entry) and "EmailFolderActive" or "EmailFolder" } }
      if count ~= "" then
        hls[#hls + 1] = { #label, #label + #count, "EmailCount" }
      end
      highlights[#lines] = hls
      if is_active(entry) then
        active_row = #lines
      end
    end
  end
  if state.folder and state.folder.search then
    lines[#lines + 1] = ""
    lines[#lines + 1] = " Search"
    highlights[#lines] = { { 0, #lines[#lines], "EmailAccount" } }
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
