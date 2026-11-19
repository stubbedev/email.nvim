local decorations = require("email.ui.decorations")
local format = require("email.format")
local layout = require("email.ui.layout")
local state = require("email.state")

local M = {}

local HEADERS = { "From", "To", "Cc" }
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

local function footer(thread_id, keymaps)
  local position = ""
  for i, entry in ipairs(state.threads) do
    if entry.id == thread_id then
      position = (" %d of %s "):format(i, state.total or "…")
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

local function fold_body(win, first, last)
  if last >= first then
    vim.api.nvim_win_call(win, function()
      vim.cmd(("%d,%dfold"):format(first, last))
    end)
  end
end

function M.show(thread_id, entries)
  local buf = layout.open_reader()
  local win = state.win.reader
  local width = vim.api.nvim_win_get_width(win)
  local lines, highlights, line_highlights, links, sections = {}, {}, {}, {}, {}
  for index, entry in ipairs(entries) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    local start = #lines + 1
    local block, block_highlights = M.lines(entry.message, entry.doc.lines, width, entry.invite, state.config)
    local offset = #lines
    local body_start = offset + #block - #entry.doc.lines
    vim.list_extend(lines, block)
    for _, hl in ipairs(block_highlights) do
      highlights[#highlights + 1] = { hl[1] + offset, hl[2], hl[3], hl[4] }
    end
    for _, line in ipairs(entry.doc.line_highlights) do
      line_highlights[#line_highlights + 1] = { body_start + line[1], line[2] }
    end
    for _, hl in ipairs(entry.doc.highlights) do
      highlights[#highlights + 1] = { body_start + hl[1], hl[2], hl[3], hl[4] }
    end
    for _, link in ipairs(entry.doc.links) do
      links[#links + 1] =
        { row = body_start + link.row, start_col = link.start_col, end_col = link.end_col, url = link.url }
    end
    sections[index] = { first = start, body = body_start, last = #lines, message = entry.message }
  end
  layout.set_lines(buf, lines)
  local decorated = decorations.rows()
  for _, hl in ipairs(highlights) do
    decorations.span(decorated, hl[1] - 1, hl[2], hl[3], hl[4])
  end
  for _, line in ipairs(line_highlights) do
    decorations.line(decorated, line[1] - 1, line[2])
  end
  for _, link in ipairs(links) do
    decorations.link(decorated, link.row - 1, link.start_col, link.end_col, link.url)
  end
  decorations.set(buf, decorated)
  state.reader_links = links
  state.sections = sections
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].foldenable = true
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zE")
  end)
  local focus = #sections
  for index, section in ipairs(sections) do
    if section.message.tags.unread then
      focus = index
      break
    end
  end
  for index = 1, focus - 1 do
    fold_body(win, sections[index].body + 1, sections[index].last)
  end
  vim.api.nvim_win_set_cursor(win, { sections[focus].first, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  local subject = format.oneline(entries[1].message.headers.Subject)
  layout.set_title("reader", subject ~= "" and vim.trim(format.fit(subject, width - 4)) or "Email")
  state.reader_footer = footer(thread_id, state.config.keymaps.reader)
  layout.set_status("reader", nil, state.reader_footer)
  return buf, sections[focus].message
end

function M.section_at(row)
  for index = #(state.sections or {}), 1, -1 do
    local section = state.sections[index]
    if row >= section.first then
      return section, index
    end
  end
  return nil
end

return M
