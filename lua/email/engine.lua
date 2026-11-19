local async = require("email.async")
local state = require("email.state")

local M = {}

local STDERR_TAIL = 4096

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local process
local pending, next_id, partial, stderr = {}, 0, {}, ""
local starting = async.mutex()

local function read_file(path)
  local fd, err = io.open(path, "rb")
  if not fd then
    error(("read %s: %s"):format(path, err), 0)
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

function M.version()
  return vim.trim(read_file(root .. "/engine/VERSION"))
end

local function fail_pending(message)
  local waiting = pending
  pending = {}
  for _, resolve in pairs(waiting) do
    resolve({ error = message })
  end
end

local function on_line(line)
  if line == "" then
    return
  end
  local ok, response = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok then
    fail_pending(("email-engine wrote a line that is not JSON (%s): %s"):format(response, line:sub(1, 200)))
    return
  end
  local resolve = pending[response.id]
  if resolve then
    pending[response.id] = nil
    resolve(response)
  end
end

local function on_stdout(_, data)
  if not data then
    return
  end
  local lines, start = {}, 1
  while true do
    local newline = data:find("\n", start, true)
    if not newline then
      break
    end
    partial[#partial + 1] = data:sub(start, newline - 1)
    lines[#lines + 1] = table.concat(partial)
    partial = {}
    start = newline + 1
  end
  if start <= #data then
    partial[#partial + 1] = data:sub(start)
  end
  if #lines > 0 then
    vim.schedule(function()
      for _, line in ipairs(lines) do
        on_line(line)
      end
    end)
  end
end

local function on_stderr(_, data)
  if data then
    stderr = (stderr .. data):sub(-STDERR_TAIL)
  end
end

local function request(method, params)
  next_id = next_id + 1
  local id = next_id
  local message = { id = id, method = method, params = params }
  local running = process or error(("email-engine is not running: %s"):format(vim.trim(stderr)), 0)
  local response = async.await(function(resolve)
    pending[id] = resolve
    running:write(vim.json.encode(message) .. "\n")
  end)
  if response.error then
    error("email-engine: " .. response.error, 0)
  end
  return response.result
end

local function binary()
  local configured = state.config.engine
  if configured then
    return configured
  end
  local bundled = root .. "/bin/email-engine"
  if vim.uv.fs_stat(bundled) then
    return bundled
  end
  return require("email.install").ensure(M.version())
end

local function account_payload(account)
  return {
    name = account.name,
    maildir = account.maildir,
    from = account.from,
    addresses = account.addresses,
    inbox = account.inbox,
    sent = account.sent,
    drafts = account.drafts,
    archive = account.archive,
    trash = account.trash,
    smtp = account.smtp,
  }
end

local function configuration()
  local config = state.config
  local raw = vim.tbl_keys(config.renderers)
  table.sort(raw)
  local accounts = {}
  for i, account in ipairs(config.accounts) do
    accounts[i] = account_payload(account)
  end
  local markdown = config.markdown
  return {
    accounts = accounts,
    markdown = {
      types = markdown.types,
      headings = markdown.headings,
      bullets = markdown.bullets,
      quote = markdown.quote,
      link = markdown.link,
      email = markdown.email,
      image = markdown.image,
    },
    alternatives = config.alternatives,
    raw_types = raw,
    images = config.images.enabled,
    html_alternative = config.html_alternative,
  }
end

local function start()
  local path = binary()
  partial, stderr = {}, ""
  local spawned
  spawned = vim.system({ path, "serve" }, { stdin = true, stdout = on_stdout, stderr = on_stderr }, function(res)
    vim.schedule(function()
      if process == spawned then
        process = nil
      end
      fail_pending(("email-engine exited with code %d: %s"):format(res.code, vim.trim(stderr)))
    end)
  end)
  process = spawned
  local hello = request("hello")
  local expected = M.version()
  if hello.version ~= expected then
    M.stop()
    error(
      ("email-engine %s at %s does not match email.nvim's engine version %s"):format(hello.version, path, expected),
      0
    )
  end
  request("configure", configuration())
end

local function ensure()
  starting(function()
    if not process then
      start()
    end
  end)
end

function M.call(method, params)
  ensure()
  return request(method, params)
end

function M.reconfigure()
  if process then
    M.call("configure", configuration())
  end
end

function M.stop()
  if process then
    local running = process
    process = nil
    running:kill("sigterm")
  end
end

local function tag_set(tags)
  local set = {}
  for _, tag in ipairs(tags or {}) do
    set[tag] = true
  end
  return set
end

local function message(view)
  view.tags = tag_set(view.tags)
  return view
end

local function thread(summary)
  return {
    id = summary.id,
    timestamp = summary.timestamp,
    tags = tag_set(summary.tags),
    authors = summary.authors,
    headers = { Subject = summary.subject },
    total = summary.total,
    message_ids = summary.message_ids or {},
  }
end

function M.threads(query, offset, limit)
  return vim.tbl_map(thread, M.call("threads", { query = query, offset = offset, limit = limit }).threads or {})
end

function M.count_threads(query)
  return M.call("count_threads", { query = query })
end

function M.prefetch(queries, limit)
  M.call("prefetch", { queries = queries, limit = limit })
end

function M.counts(queries)
  return M.call("counts", { queries = queries })
end

function M.revision()
  return M.call("revision")
end

function M.newest_message(thread_id, query)
  return M.call("newest_message", { thread = thread_id, query = query })
end

function M.message(id, alternatives, render)
  return message(M.call("message", { id = id, alternatives = alternatives, render = render }))
end

function M.thread(id, render)
  return vim.tbl_map(message, M.call("thread", { id = id, render = render }))
end

function M.warm(ids, render)
  M.call("warm", { ids = ids, render = render })
end

function M.render(blocks, render)
  return M.call("render", { blocks = blocks, render = render })
end

function M.tag(ids, changes)
  M.call("tag", { ids = ids, changes = changes })
end

function M.extract(id, part, path)
  return M.call("extract", { id = id, part = part, path = path })
end

function M.reply(id, all, preferred)
  return M.call("reply", { id = id, all = all, preferred = preferred })
end

function M.addresses()
  return M.call("addresses") or {}
end

function M.relocate(ids, action, folder, stash, preferred)
  return M.call("relocate", { ids = ids, action = action, folder = folder, stash = stash, preferred = preferred })
end

function M.undo(undo)
  M.call("undo", undo)
end

function M.permanent_delete(ids, preferred)
  return M.call("permanent_delete", { ids = ids, preferred = preferred })
end

function M.folders(ids, preferred)
  return M.call("folders", { ids = ids, preferred = preferred })
end

function M.save_draft(draft)
  return M.call("save_draft", draft)
end

function M.send(draft)
  M.call("send", draft)
end

return M
