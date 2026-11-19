local format = require("email.format")
local highlight = require("email.ui.highlight")
local layout = require("email.ui.layout")
local state = require("email.state")

local M = {}

local HEADERS = { "From", "To", "Cc", "Subject" }
local LABEL_WIDTH = 9

local function header_line(label, value)
  return format.fit(label .. ":", LABEL_WIDTH) .. " " .. format.oneline(value)
end

function M.lines(message, body, width)
  local lines, labels = {}, {}
  local function add(label, value)
    lines[#lines + 1] = header_line(label, value)
    labels[#lines] = #label + 1
  end
  for _, name in ipairs(HEADERS) do
    local value = message.headers[name]
    if value and value ~= "" then
      add(name, value)
    end
  end
  add("Date", os.date("%Y-%m-%d %H:%M", message.timestamp))
  if #message.attachments > 0 then
    local names = {}
    for i, attachment in ipairs(message.attachments) do
      names[i] = ("%s (%s)"):format(attachment.filename, format.size(attachment.size))
    end
    add("Files", table.concat(names, ", "))
  end
  lines[#lines + 1] = string.rep("─", width)
  local separator = #lines
  lines[#lines + 1] = ""
  vim.list_extend(lines, body)
  return lines, labels, separator
end

function M.show(message, body)
  local buf = layout.open_reader()
  local width = vim.api.nvim_win_get_width(state.win.reader)
  local lines, labels, separator = M.lines(message, body, width)
  layout.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, highlight.ns, 0, -1)
  for row, len in pairs(labels) do
    highlight.apply(buf, row - 1, { { 0, len, "EmailHeader" } })
  end
  highlight.apply(buf, separator - 1, { { 0, #lines[separator], "EmailSeparator" } })
  if not vim.b[buf].email_treesitter then
    vim.treesitter.start(buf, "markdown")
    vim.b[buf].email_treesitter = true
  end
  vim.api.nvim_win_set_cursor(state.win.reader, { 1, 0 })
  local subject = format.oneline(message.headers.Subject)
  layout.set_title("reader", subject ~= "" and vim.trim(format.fit(subject, width - 4)) or "Email")
  return buf
end

return M
