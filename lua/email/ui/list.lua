local format = require("email.format")
local highlight = require("email.ui.highlight")
local layout = require("email.ui.layout")
local state = require("email.state")

local M = {}

local function title()
  local folder = state.folder
  if folder.search then
    return "Search: " .. folder.search
  end
  return state.config.accounts[folder.account].name .. " · " .. folder.name
end

local function footer(width)
  local pages = math.max(1, math.ceil(state.total / state.config.page_size))
  local left = (" Page %d/%d "):format(state.page, pages)
  local right = (" %d messages "):format(state.total)
  local fill = math.max(0, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
  return {
    { left, "FloatFooter" },
    { string.rep("─", fill), "FloatBorder" },
    { right, "FloatFooter" },
  }
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
  for i, message in ipairs(state.messages) do
    lines[i], highlights[i] = format.row(message, width, state.config.icons, now)
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
  end
  vim.api.nvim_win_set_cursor(win, { math.min(cursor, #lines), 0 })
  layout.set_title("list", title())
  layout.set_footer("list", footer(width), "left")
end

function M.selected()
  if not state.win.list or not vim.api.nvim_win_is_valid(state.win.list) then
    return nil
  end
  return state.messages[vim.api.nvim_win_get_cursor(state.win.list)[1]]
end

function M.select_id(id)
  for i, message in ipairs(state.messages) do
    if message.id == id then
      vim.api.nvim_win_set_cursor(state.win.list, { i, 0 })
      return message
    end
  end
  return nil
end

return M
