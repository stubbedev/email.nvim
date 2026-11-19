local async = require("email.async")
local decorations = require("email.ui.decorations")
local format = require("email.format")
local layout = require("email.ui.layout")
local sidebar = require("email.ui.sidebar")
local state = require("email.state")

local M = {}

local PAUSE_EVERY = 64

local generation = 0
local shown = { count = 0, width = 0, rows = decorations.rows() }

local function title()
  local folder = state.folder
  local icons = state.config.folder_icons
  if folder.search then
    return icons.search .. " " .. folder.search
  end
  return (folder.smart and icons.search or format.folder_icon(folder.name, icons)) .. " " .. sidebar.label(folder)
end

local function status()
  local total = state.total or "…"
  local left = (" %d of %s loaded "):format(#state.threads, total)
  local marked = vim.tbl_count(state.marked)
  local right = marked > 0 and (" %d marked · %s messages "):format(marked, total) or (" %s messages "):format(total)
  return left, right
end

local function window()
  local buf, win = state.buf.list, state.win.list
  if buf and win and vim.api.nvim_win_is_valid(win) then
    return buf, win
  end
  return nil
end

local function row_into(rows, index, width, now)
  local thread = state.threads[index]
  local marked = state.marked[thread.id]
  local line, highlights = format.row(thread, width, state.config.icons, now, marked)
  local row = index - 1
  rows[row] = nil
  for _, hl in ipairs(highlights) do
    decorations.span(rows, row, hl[1], hl[2], hl[3])
  end
  if marked then
    decorations.line(rows, row, "EmailMarked")
  end
  return line
end

local function build(from, to, width, rows)
  local now = os.time()
  local lines = {}
  for index = from, to do
    lines[#lines + 1] = row_into(rows, index, width, now)
    if index % PAUSE_EVERY == 0 then
      async.pause()
    end
  end
  return lines
end

local function chrome()
  if window() then
    layout.set_title("list", title())
    layout.set_status("list", status())
  end
end

M.chrome = chrome

function M.render(keep_id)
  local buf, win = window()
  if not buf or not win then
    return
  end
  generation = generation + 1
  local mine = generation
  keep_id = keep_id or (M.selected() or {}).id
  local width = vim.api.nvim_win_get_width(win)
  local count = #state.threads
  local rows = decorations.rows()
  local lines = build(1, count, width, rows)
  if mine ~= generation then
    return
  end
  if count ~= #state.threads or not window() then
    return M.render(keep_id)
  end
  if count == 0 then
    lines = { "  No messages" }
  end
  layout.set_lines(buf, lines)
  decorations.set(buf, rows)
  shown = { count = count, width = width, rows = rows }
  local cursor = 1
  for index, thread in ipairs(state.threads) do
    if thread.id == keep_id then
      cursor = index
      break
    end
  end
  vim.api.nvim_win_set_cursor(win, { math.min(cursor, math.max(count, 1)), 0 })
  chrome()
end

function M.append()
  local buf, win = window()
  if not buf or not win then
    return
  end
  local width = vim.api.nvim_win_get_width(win)
  if shown.count == 0 or width ~= shown.width or shown.count > #state.threads then
    return M.render()
  end
  generation = generation + 1
  local mine = generation
  local from, to = shown.count + 1, #state.threads
  local lines = build(from, to, width, shown.rows)
  if mine ~= generation then
    return
  end
  if to ~= #state.threads then
    return M.render()
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, from - 1, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  shown.count = to
  chrome()
end

function M.update(indices)
  local buf, win = window()
  if not buf or not win or shown.count ~= #state.threads then
    return M.render()
  end
  local width = vim.api.nvim_win_get_width(win)
  if width ~= shown.width then
    return M.render()
  end
  local now = os.time()
  vim.bo[buf].modifiable = true
  for _, index in ipairs(indices) do
    if state.threads[index] then
      local line = row_into(shown.rows, index, width, now)
      vim.api.nvim_buf_set_lines(buf, index - 1, index, false, { line })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  chrome()
end

function M.index_of(id)
  for index, thread in ipairs(state.threads) do
    if thread.id == id then
      return index
    end
  end
  return nil
end

function M.selected()
  if not state.win.list or not vim.api.nvim_win_is_valid(state.win.list) then
    return nil
  end
  return state.threads[vim.api.nvim_win_get_cursor(state.win.list)[1]]
end

function M.select_id(id)
  local index = M.index_of(id)
  if index then
    vim.api.nvim_win_set_cursor(state.win.list, { index, 0 })
    return state.threads[index]
  end
  return nil
end

return M
