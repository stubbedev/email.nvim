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
  for i, attachment in ipairs(message.attachments) do
    local icon, icon_hl = format.file_icon(attachment.filename, config)
    local entry = ("%s %s (%s)"):format(icon, attachment.filename, format.size(attachment.size))
    if i == 1 then
      add("Files", entry)
    else
      lines[#lines + 1] = label_pad .. entry
    end
    highlights[#highlights + 1] = { #lines, LABEL_WIDTH + 1, LABEL_WIDTH + 1 + #icon, icon_hl }
  end
  lines[#lines + 1] = string.rep("─", width)
  highlights[#highlights + 1] = { #lines, 0, #lines[#lines], "EmailSeparator" }
  lines[#lines + 1] = ""
  vim.list_extend(lines, body)
  return lines, highlights
end

function M.show(message, body, invite)
  local buf = layout.open_reader()
  local width = vim.api.nvim_win_get_width(state.win.reader)
  local lines, highlights = M.lines(message, body, width, invite, state.config)
  layout.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, highlight.ns, 0, -1)
  for _, hl in ipairs(highlights) do
    highlight.apply(buf, hl[1] - 1, { { hl[2], hl[3], hl[4] } })
  end
  if not vim.b[buf].email_treesitter then
    vim.treesitter.start(buf, "markdown")
    vim.b[buf].email_treesitter = true
  end
  vim.api.nvim_win_set_cursor(state.win.reader, { 1, 0 })
  local subject = format.oneline(message.headers.Subject)
  layout.set_title("reader", subject ~= "" and vim.trim(format.fit(subject, width - 4)) or "Email")
  return buf, #lines - #body
end

return M
