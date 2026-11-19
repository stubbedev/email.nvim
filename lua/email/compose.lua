local async = require("email.async")
local engine = require("email.engine")
local format = require("email.format")
local layout = require("email.ui.layout")
local markdown = require("email.markdown")
local render = require("email.render")
local state = require("email.state")

local M = {}

local QUOTE_WIDTH = 72

local function preferred()
  return state.folder and state.folder.account or 0
end

function M.account_of_message(message)
  local accounts = message.accounts or {}
  for _, number in ipairs(accounts) do
    if number == preferred() then
      return state.config.accounts[number]
    end
  end
  local number = accounts[1]
    or error(("message %s has no file in any configured account maildir"):format(message.id), 0)
  return state.config.accounts[number]
end

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

local function extract_attachments(id, attachments)
  local dir = vim.fn.tempname()
  local paths = {}
  for i, attachment in ipairs(attachments) do
    local sub = ("%s/%d"):format(dir, i)
    vim.fn.mkdir(sub, "p")
    local path = sub .. "/" .. attachment.filename:gsub("/", "_")
    engine.extract(id, attachment.part, path)
    paths[#paths + 1] = path
  end
  return paths
end

local function signature(account)
  if not account or not account.signature or account.signature == "" then
    return {}
  end
  local lines = { "-- " }
  vim.list_extend(lines, vim.split(vim.trim(account.signature), "\n", { plain = true }))
  return lines
end

local function opening(account)
  local body = { "", "" }
  local sig = signature(account)
  if #sig > 0 then
    vim.list_extend(body, sig)
    body[#body + 1] = ""
  end
  return body
end

function M.new(account, to)
  local body = { "" }
  local sig = signature(account)
  if #sig > 0 then
    body[#body + 1] = ""
    vim.list_extend(body, sig)
  end
  return {
    headers = { From = account.from, To = to or "", Cc = "", Subject = "" },
    hidden = {},
    body = body,
  }
end

local function threading(reply)
  return { ["In-Reply-To"] = reply.in_reply_to, References = reply.references }
end

function M.reply(id, all)
  local message = engine.message(id)
  local reply = engine.reply(id, all, preferred())
  local body = opening(state.config.accounts[reply.account])
  body[#body + 1] = ("On %s, %s wrote:"):format(os.date("%Y-%m-%d %H:%M", message.timestamp), message.headers.From)
  vim.list_extend(body, quote(plain_text(message)))
  return {
    headers = { From = reply.from, To = reply.to, Cc = reply.cc, Subject = reply.subject },
    hidden = threading(reply),
    body = body,
    reply_to = id,
  }
end

function M.forward(id)
  local message = engine.message(id)
  local account = M.account_of_message(message)
  local body = opening(account)
  body[#body + 1] = "---------- Forwarded message ----------"
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

local VISIBLE_HEADERS = { "From", "To", "Cc", "Bcc", "Reply-To", "Subject" }

function M.edit(id)
  local message = engine.message(id, { "text/plain", "text/html" })
  if not message.tags.draft then
    error("only drafts can be edited; this message is not tagged draft", 0)
  end
  local headers = {}
  for _, name in ipairs(VISIBLE_HEADERS) do
    headers[name] = message.headers[name] or ""
  end
  return {
    headers = headers,
    hidden = { ["In-Reply-To"] = message.headers["In-Reply-To"], References = message.headers.References },
    body = render.body(message, {}),
    attach = extract_attachments(id, message.attachments),
    draft_id = id,
  }
end

function M.calendar_reply(id, status)
  local reply = engine.call("calendar_reply", { id = id, status = status, preferred = preferred() })
  return {
    headers = { From = reply.from, To = reply.to, Cc = "", Subject = reply.subject },
    hidden = threading(reply),
    body = { reply.body },
    reply_to = reply.replying,
    calendar = { ics = reply.ics, label = reply.label },
  }
end

local function payload(parsed, draft)
  local headers = parsed.headers
  return {
    from = headers.From or "",
    to = headers.To or "",
    cc = headers.Cc or "",
    bcc = headers.Bcc or "",
    reply_to_header = headers["Reply-To"] or "",
    subject = headers.Subject or "",
    in_reply_to = draft.hidden["In-Reply-To"] or "",
    references = draft.hidden.References or "",
    body = parsed.body,
    attachments = parsed.attach,
    calendar = draft.calendar and { ics = draft.calendar.ics, method = "REPLY" } or nil,
    replying = draft.reply_to or "",
    draft_id = draft.draft_id or "",
  }
end

local function deliver(session, parsed)
  layout.with_busy("Sending", function()
    engine.send(payload(parsed, session.draft))
  end)
  session.draft.draft_id = nil
  session.close()
  vim.notify(("email.nvim: sent %q"):format(parsed.headers.Subject or ""))
  local sync = state.config.sync_cmd
  if sync then
    vim.system(sync, {}, function() end)
  end
end

local function flush_pending()
  local pending = state.pending_send
  if not pending then
    return
  end
  state.pending_send = nil
  pending.timer:stop()
  pending.timer:close()
  local done = false
  async.run(pending.session.lock, function()
    local ok, err = pcall(deliver, pending.session, pending.parsed)
    done = true
    if not ok then
      error(err, 0)
    end
  end)
  return function()
    return done
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("email.nvim.send", { clear = true }),
  callback = function()
    local finished = flush_pending()
    if finished then
      vim.wait(30000, finished, 50)
    end
  end,
})

function M.send(session)
  async.run(session.lock, function()
    if session.closed then
      return
    end
    local parsed = session.current()
    engine.call("check_draft", payload(parsed, session.draft))
    local delay = state.config.send_delay
    if delay <= 0 then
      deliver(session, parsed)
      return
    end
    flush_pending()
    session.hide()
    local timer = assert(vim.uv.new_timer())
    state.pending_send = { session = session, parsed = parsed, timer = timer }
    timer:start(delay * 1000, 0, vim.schedule_wrap(flush_pending))
    local undo = state.config.keymaps.global.undo
    vim.notify(
      ("email.nvim: sending %q in %ds%s"):format(
        parsed.headers.Subject or "",
        delay,
        undo and (" · " .. format.key(type(undo) == "table" and undo[1] or undo) .. " to undo") or ""
      )
    )
  end)
end

function M.cancel_send()
  local pending = state.pending_send
  if not pending then
    return false
  end
  state.pending_send = nil
  pending.timer:stop()
  pending.timer:close()
  pending.session.show()
  vim.notify("email.nvim: sending cancelled")
  return true
end

function M.attach(session)
  local function add(paths)
    if paths and #paths > 0 and vim.api.nvim_buf_is_valid(session.buf) then
      require("email.ui.composer").add_attachments(session.buf, paths)
    end
  end
  if state.config.attach_picker then
    state.config.attach_picker(add)
    return
  end
  vim.ui.input({ prompt = "Attach file: ", completion = "file" }, function(path)
    if path and path ~= "" then
      add({ path })
    end
  end)
end

function M.save(session)
  vim.bo[session.buf].modified = false
  async.run(session.lock, function()
    if session.closed then
      return
    end
    local ok, err = pcall(function()
      session.draft.draft_id = engine.save_draft(payload(session.current(), session.draft))
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
