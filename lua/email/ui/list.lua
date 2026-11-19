local format = require("email.format")
local highlight = require("email.ui.highlight")
local layout = require("email.ui.layout")
local sidebar = require("email.ui.sidebar")
local state = require("email.state")

local M = {}

local function title()
  local folder = state.folder
  local icons = state.config.folder_icons
  if folder.search then
    return icons.search .. " " .. folder.search
  end
  return (folder.smart and icons.search or format.folder_icon(folder.name, icons)) .. " " .. sidebar.label(folder)
end

local function status()
  local left = (" %d of %d loaded "):format(#state.threads, state.total)
  local marked = vim.tbl_count(state.marked)
  local right = marked > 0 and (" %d marked · %d messages "):format(marked, state.total)
    or (" %d messages "):format(state.total)
  return left, right
end

function M.render(keep_id)
  local buf, win = state.buf.list, state.win.list
  if not buf or not vim.api.nvim_win_is_valid(win) then
    return
  end
  keep_id = keep_id or (M.selected() or {}).id
  local width = vim.api.nvim_win_get_width(win)
  local now = os.time()
  local lines, highlights, cursor = {}, {}, 1
  for i, message in ipairs(state.threads) do
    lines[i], highlights[i] = format.row(message, width, state.config.icons, now, state.marked[message.id])
    if message.id == keep_id then
      cursor = i
    end
  end
  if #lines == 0 then
    lines = { "  No messages" }
  end
  layout.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, highlight.ns, 0, -1)
  for i, hls in ipairs(highlights) do
    highlight.apply(buf, i - 1, hls)
    if state.marked[state.threads[i].id] then
      vim.api.nvim_buf_set_extmark(buf, highlight.ns, i - 1, 0, { line_hl_group = "EmailMarked" })
    end
  end
  vim.api.nvim_win_set_cursor(win, { math.min(cursor, #lines), 0 })
  layout.set_title("list", title())
  layout.set_status("list", status())
end

function M.selected()
  if not state.win.list or not vim.api.nvim_win_is_valid(state.win.list) then
    return nil
  end
  return state.threads[vim.api.nvim_win_get_cursor(state.win.list)[1]]
end

function M.select_id(id)
  for i, message in ipairs(state.threads) do
    if message.id == id then
      vim.api.nvim_win_set_cursor(state.win.list, { i, 0 })
      return message
    end
  end
  return nil
end

return M
