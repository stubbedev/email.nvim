local async = require("email.async")
local ical = require("email.ical")
local layout = require("email.ui.layout")
local maildir = require("email.maildir")
local markdown = require("email.markdown")
local mime = require("email.mime")
local notmuch = require("email.notmuch")
local parse = require("email.parse")
local render = require("email.render")
local state = require("email.state")

local M = {}

local THREAD_HEADERS = { "In-Reply-To", "References" }
local VISIBLE_HEADERS = { "From", "To", "Cc", "Bcc", "Reply-To", "Subject" }

local function hex(bytes)
  return (bytes:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

function M.root(account)
  return notmuch.database_path() .. "/" .. account.maildir
end

function M.account_for_address(addr)
  addr = addr:lower()
  for _, account in ipairs(state.config.accounts) do
    for _, candidate in ipairs(account.addresses) do
      if candidate:lower() == addr then
        return account
      end
    end
  end
  return nil
end

local function owns(account, message)
  local root = M.root(account)
  for _, file in ipairs(message.files) do
    if maildir.split(file, root) then
      return true
    end
  end
  return false
end

function M.account_of_message(message)
  local preferred = state.folder and state.folder.account and state.config.accounts[state.folder.account]
  if preferred and owns(preferred, message) then
    return preferred
  end
  for _, account in ipairs(state.config.accounts) do
    if owns(account, message) then
      return account
    end
  end
  error(("message %s has no file in any configured account maildir"):format(message.id), 0)
end

local QUOTE_WIDTH = 72

local function plain_text(message)
  local config = state.config
  local segments = render.segments(message, config.renderers, config.markdown.types)
  return markdown.render(segments, QUOTE_WIDTH, vim.tbl_extend("force", config.markdown, { inline_urls = true })).lines
end

local function quote(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line == "" and ">" or ("> " .. line)
  end
  return out
end

local function write_file(path, data)
  local fd, err = io.open(path, "wb")
  if not fd then
    error(("write %s: %s"):format(path, err), 0)
  end
  fd:write(data)
  fd:close()
end

local function read_file(path)
  local fd, err = io.open(path, "rb")
  if not fd then
    error(("read attachment %s: %s"):format(path, err), 0)
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

local function extract_attachments(id, attachments)
  local dir = vim.fn.tempname()
  local paths = {}
  for i, attachment in ipairs(attachments) do
    local sub = ("%s/%d"):format(dir, i)
    vim.fn.mkdir(sub, "p")
    local path = sub .. "/" .. attachment.filename:gsub("/", "_")
    write_file(path, notmuch.part(id, attachment.part))
    paths[#paths + 1] = path
  end
  return paths
end

local function raw_headers(raw)
  local block = raw:gsub("\r\n", "\n"):match("^(.-)\n\n") or raw
  local headers, last = {}, nil
  for line in (block .. "\n"):gmatch("(.-)\n") do
    local name, value = line:match("^([%w-]+):%s*(.*)$")
    if name then
      last = name:lower()
      headers[last] = value
    elseif last and line:match("^%s") then
      headers[last] = headers[last] .. " " .. vim.trim(line)
    end
  end
  return headers
end

function M.new(account, to)
  return {
    headers = { From = account.from, To = to or "", Cc = "", Subject = "" },
    hidden = {},
    body = { "" },
  }
end

function M.reply(id, all)
  local config = state.config
  local message = parse.message(notmuch.show(id), config.alternatives)
  local reply = notmuch.reply_headers(id, all)
  local body =
    { "", "", ("On %s, %s wrote:"):format(os.date("%Y-%m-%d %H:%M", message.timestamp), message.headers.From) }
  vim.list_extend(body, quote(plain_text(message)))
  return {
    headers = { From = reply.From, To = reply.To or "", Cc = reply.Cc or "", Subject = reply.Subject or "" },
    hidden = { ["In-Reply-To"] = reply["In-reply-to"], References = reply.References },
    body = body,
    reply_to = id,
  }
end

function M.forward(id)
  local config = state.config
  local message = parse.message(notmuch.show(id), config.alternatives)
  local account = M.account_of_message(message)
  local body = { "", "", "---------- Forwarded message ----------" }
  vim.list_extend(body, render.header_lines(message.headers))
  body[#body + 1] = ""
  vim.list_extend(body, plain_text(message))
  return {
    headers = { From = account.from, To = "", Cc = "", Subject = "Fwd: " .. (message.headers.Subject or "") },
    hidden = {},
    body = body,
    attach = extract_attachments(id, message.attachments),
  }
end

function M.edit(id)
  local message = parse.message(notmuch.show(id), { "text/plain", "text/html" })
  if not message.tags.draft then
    error("only drafts can be edited; this message is not tagged draft", 0)
  end
  local raw = raw_headers(notmuch.raw(id))
  local headers = {}
  for _, name in ipairs(VISIBLE_HEADERS) do
    headers[name] = message.headers[name] or ""
  end
  local hidden = {}
  for _, name in ipairs(THREAD_HEADERS) do
    hidden[name] = raw[name:lower()]
  end
  return {
    headers = headers,
    hidden = hidden,
    body = render.body(message, {}),
    attach = extract_attachments(id, message.attachments),
    draft_id = id,
  }
end

local PARTSTAT_WORDS = {
  ACCEPTED = { subject = "Accepted", verb = "accepted" },
  DECLINED = { subject = "Declined", verb = "declined" },
  TENTATIVE = { subject = "Tentative", verb = "tentatively accepted" },
}

function M.invite_text(id, message)
  local calendar = message.calendars[1] or error("this message has no calendar invite", 0)
  return calendar.content or notmuch.part(id, calendar.part)
end

function M.calendar_reply(id, partstat)
  local words = PARTSTAT_WORDS[partstat] or error(("unknown participation status %s"):format(partstat), 0)
  local message = parse.message(notmuch.show(id), state.config.alternatives)
  local calendar = ical.parse(M.invite_text(id, message))
  if calendar.method ~= "REQUEST" then
    error(("the calendar part is %s, not an invitation (REQUEST)"):format(calendar.method or "missing its METHOD"), 0)
  end
  local reply = notmuch.reply_headers(id, false)
  local me = mime.parse_addresses(reply.From or "")[1] or error("notmuch reply produced no From address", 0)
  local to = reply.To or ""
  local organizer = calendar.event and calendar.event.props.ORGANIZER
  if organizer then
    local name = organizer.params.CN and organizer.params.CN:gsub('^"(.*)"$', "%1")
    to = mime.display_address({ name = name, addr = ical.mailto(organizer.value) })
  end
  return {
    headers = {
      From = reply.From,
      To = to,
      Cc = "",
      Subject = words.subject .. ": " .. (ical.summary(calendar) or message.headers.Subject or ""),
    },
    hidden = { ["In-Reply-To"] = reply["In-reply-to"], References = reply.References },
    body = { ("%s has %s the invitation."):format(me.name or me.addr, words.verb) },
    reply_to = id,
    calendar = { ics = ical.reply(calendar, me.addr, me.name, partstat, os.time()), label = words.subject },
  }
end

local function finalize(parsed, draft, require_recipients)
  local from = mime.parse_addresses(parsed.headers.From or "")[1] or error("From is empty", 0)
  local domain = from.addr:match("@([^@]+)$") or error(("From address %q has no domain"):format(from.addr), 0)
  local account = M.account_for_address(from.addr)
    or error(("From address %s belongs to no configured account"):format(from.addr), 0)
  if require_recipients then
    local any = false
    for _, name in ipairs({ "To", "Cc", "Bcc" }) do
      any = any or #mime.parse_addresses(parsed.headers[name] or "") > 0
    end
    if not any then
      error("the message has no recipients", 0)
    end
  end
  local epoch = os.time()
  local message_id = mime.message_id(epoch, hex(vim.uv.random(8)), domain)
  local headers = { { "Date", mime.date(epoch) } }
  for _, name in ipairs(VISIBLE_HEADERS) do
    local value = parsed.headers[name]
    if value and value ~= "" then
      headers[#headers + 1] = { name, value }
    end
  end
  headers[#headers + 1] = { "Message-ID", message_id }
  for _, name in ipairs(THREAD_HEADERS) do
    local value = draft.hidden[name]
    if value and value ~= "" then
      headers[#headers + 1] = { name, value }
    end
  end
  local attachments = {}
  for i, path in ipairs(parsed.attach) do
    attachments[i] = { filename = vim.fs.basename(path), data = read_file(path) }
  end
  return account,
    message_id:sub(2, -2),
    mime.build({
      headers = headers,
      body = parsed.body,
      attachments = attachments,
      alternatives = draft.calendar and {
        { content_type = "text/calendar; charset=utf-8; method=REPLY", data = draft.calendar.ics },
      } or {},
      boundary = "=_" .. hex(vim.uv.random(12)),
    })
end

local function remove_draft(draft)
  if not draft.draft_id then
    return
  end
  local files = notmuch.files_by_id({ draft.draft_id })[draft.draft_id]
  local removed = false
  for _, account in ipairs(state.config.accounts) do
    local root = M.root(account)
    for _, file in ipairs(files) do
      if maildir.split(file, root) == account.drafts then
        local ok, err = vim.uv.fs_unlink(file)
        if not ok then
          error(("remove draft %s: %s"):format(file, err), 0)
        end
        removed = true
      end
    end
  end
  if removed then
    notmuch.reindex()
  end
  draft.draft_id = nil
end

function M.send(session)
  async.run(session.lock, function()
    if session.closed then
      return
    end
    local parsed = session.current()
    local account, _, message = finalize(parsed, session.draft, true)
    layout.with_busy("Sending", function()
      async.checked(state.config.send_cmd, { stdin = message })
      notmuch.insert(account.maildir .. "/" .. account.sent, message, { "+sent", "-inbox", "-unread" })
      if session.draft.reply_to then
        notmuch.tag({ session.draft.reply_to }, { "+replied" })
      end
      remove_draft(session.draft)
    end)
    session.close()
    vim.notify(("email.nvim: sent %q"):format(parsed.headers.Subject or ""))
  end)
end

function M.save(session)
  vim.bo[session.buf].modified = false
  async.run(session.lock, function()
    if session.closed then
      return
    end
    local ok, err = pcall(function()
      local parsed = session.current()
      local account, message_id, message = finalize(parsed, session.draft, false)
      notmuch.insert(account.maildir .. "/" .. account.drafts, message, { "+draft", "-inbox", "-unread" })
      remove_draft(session.draft)
      session.draft.draft_id = message_id
    end)
    if not ok then
      if vim.api.nvim_buf_is_valid(session.buf) then
        vim.bo[session.buf].modified = true
      end
      error(err, 0)
    end
    vim.notify("email.nvim: draft saved")
  end)
end

return M
