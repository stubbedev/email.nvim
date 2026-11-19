local format = require("email.format")
local highlight = require("email.ui.highlight")
local layout = require("email.ui.layout")
local state = require("email.state")

local M = {}

local HEADERS = { "From", "To", "Cc", "Subject" }
local LABEL_WIDTH = 9
local INVITE_ACTIONS = { { "accept", "accept" }, { "decline", "decline" }, { "tentative", "maybe" } }

local function invite_hint(keymaps)
  local hints = {}
  for _, action in ipairs(INVITE_ACTIONS) do
    local lhs = keymaps[action[1]]
    if lhs then
      hints[#hints + 1] = format.key(type(lhs) == "table" and lhs[1] or lhs) .. " " .. action[2]
    end
  end
  return table.concat(hints, " · ")
end

function M.lines(message, body, width, invite, config)
  local lines, highlights = {}, {}
  local label_pad = string.rep(" ", LABEL_WIDTH + 1)
  local function add(label, value)
    lines[#lines + 1] = format.fit(label .. ":", LABEL_WIDTH) .. " " .. value
    highlights[#highlights + 1] = { #lines, 0, #label + 1, "EmailHeader" }
  end
  for _, name in ipairs(HEADERS) do
    local value = message.headers[name]
    if value and value ~= "" then
      add(name, format.oneline(value))
    end
  end
  add("Date", os.date("%Y-%m-%d %H:%M", message.timestamp))
  if invite then
    local summary = invite.summary or "(untitled event)"
    local text = config.icons.invite .. " " .. summary
    if invite.method == "REQUEST" then
      text = text .. "  (" .. invite_hint(config.keymaps.global) .. ")"
    end
    add("Invite", text)
    local start = LABEL_WIDTH + 1
    highlights[#highlights + 1] = { #lines, start, start + #config.icons.invite + 1 + #summary, "EmailInvite" }
  end
  local attachments = message.attachments
  local listed = #attachments <= format.MAX_LISTED_ATTACHMENTS and #attachments or format.MAX_LISTED_ATTACHMENTS - 1
  for i = 1, listed do
    local attachment = attachments[i]
    local icon, icon_hl = format.file_icon(attachment.filename, config)
    local entry = ("%s %s (%s)"):format(icon, attachment.filename, format.size(attachment.size))
    if i == 1 then
      add("Files", entry)
    else
      lines[#lines + 1] = label_pad .. entry
    end
    highlights[#highlights + 1] = { #lines, LABEL_WIDTH + 1, LABEL_WIDTH + 1 + #icon, icon_hl }
  end
  if listed < #attachments then
    local total = 0
    for _, attachment in ipairs(attachments) do
      total = total + (attachment.size or 0)
    end
    local summary = ("… %d more, %s total"):format(#attachments - listed, format.size(total))
    local browse = config.keymaps.global.attachments
    if browse then
      summary = summary .. " · " .. format.key(type(browse) == "table" and browse[1] or browse) .. " to browse"
    end
    lines[#lines + 1] = label_pad .. summary
    highlights[#highlights + 1] = { #lines, LABEL_WIDTH + 1, #lines[#lines], "Comment" }
  end
  lines[#lines + 1] = string.rep("─", width)
  highlights[#highlights + 1] = { #lines, 0, #lines[#lines], "EmailSeparator" }
  lines[#lines + 1] = ""
  vim.list_extend(lines, body)
  return lines, highlights
end

local function footer(message, keymaps)
  local position = ""
  for i, entry in ipairs(state.messages) do
    if entry.id == message.id then
      position = (" %d of %d "):format(i + (state.page - 1) * state.config.page_size, state.total)
    end
  end
  local hints = {}
  for _, action in ipairs({ { "close_reader", "back" }, { "prev_message", "prev" }, { "next_message", "next" } }) do
    local lhs = keymaps[action[1]]
    if lhs then
      hints[#hints + 1] = format.key(type(lhs) == "table" and lhs[1] or lhs) .. " " .. action[2]
    end
  end
  return position .. (#hints > 0 and ("· " .. table.concat(hints, " · ") .. " ") or "")
end

function M.show(message, doc, invite)
  local buf = layout.open_reader()
  local width = vim.api.nvim_win_get_width(state.win.reader)
  local lines, highlights = M.lines(message, doc.lines, width, invite, state.config)
  local first_row = #lines - #doc.lines
  layout.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, highlight.ns, 0, -1)
  for _, hl in ipairs(highlights) do
    highlight.apply(buf, hl[1] - 1, { { hl[2], hl[3], hl[4] } })
  end
  for _, line in ipairs(doc.line_highlights) do
    vim.api.nvim_buf_set_extmark(buf, highlight.ns, first_row + line[1] - 1, 0, { line_hl_group = line[2] })
  end
  for _, hl in ipairs(doc.highlights) do
    highlight.apply(buf, first_row + hl[1] - 1, { { hl[2], hl[3], hl[4] } })
  end
  state.reader_links = {}
  for _, link in ipairs(doc.links) do
    local row = first_row + link.row
    vim.api.nvim_buf_set_extmark(buf, highlight.ns, row - 1, link.start_col, {
      end_col = link.end_col,
      url = link.url,
    })
    state.reader_links[#state.reader_links + 1] =
      { row = row, start_col = link.start_col, end_col = link.end_col, url = link.url }
  end
  vim.api.nvim_win_set_cursor(state.win.reader, { 1, 0 })
  local subject = format.oneline(message.headers.Subject)
  layout.set_title("reader", subject ~= "" and vim.trim(format.fit(subject, width - 4)) or "Email")
  state.reader_footer = footer(message, state.config.keymaps.reader)
  layout.set_status("reader", nil, state.reader_footer)
  return buf, first_row
end

return M
