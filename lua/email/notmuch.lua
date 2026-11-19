local async = require("email.async")

local M = {}

local serialized = async.mutex()

local function run(args, opts)
  opts = opts or {}
  local cmd = { "notmuch" }
  vim.list_extend(cmd, args)
  return serialized(function()
    return async.checked(cmd, { stdin = opts.stdin, text = not opts.binary })
  end)
end

local function decode(json)
  return vim.json.decode(json, { luanil = { object = true, array = true } })
end

local function collect(nodes, out)
  nodes = nodes or {}
  for i = 1, table.maxn(nodes) do
    local node = nodes[i] or {}
    if node[1] and node[1].match then
      out[#out + 1] = node[1]
    end
    collect(node[2], out)
  end
end

local function shown(json)
  local out = {}
  for _, thread in ipairs(decode(json)) do
    collect(thread, out)
  end
  return out
end

function M.id_query(id)
  return 'id:"' .. (id:gsub('"', '""')) .. '"'
end

function M.ids_query(ids)
  local parts = {}
  for i, id in ipairs(ids) do
    parts[i] = M.id_query(id)
  end
  return table.concat(parts, " or ")
end

function M.page(query, limit, offset)
  local ids = decode(run({
    "search",
    "--format=json",
    "--output=messages",
    "--sort=newest-first",
    "--limit=" .. limit,
    "--offset=" .. offset,
    "--",
    query,
  }))
  if #ids == 0 then
    return {}
  end
  local by_id = {}
  for _, message in
    ipairs(shown(run({
      "show",
      "--format=json",
      "--body=false",
      "--entire-thread=false",
      "--exclude=false",
      "--",
      M.ids_query(ids),
    })))
  do
    by_id[message.id] = message
  end
  local out = {}
  for i, id in ipairs(ids) do
    out[i] = by_id[id] or error(("notmuch search returned %s but notmuch show did not"):format(id), 0)
  end
  return out
end

function M.count(query)
  return tonumber(vim.trim(run({ "count", "--", query })))
end

function M.counts(queries)
  local out = run({ "count", "--batch" }, { stdin = table.concat(queries, "\n") .. "\n" })
  local counts = {}
  for line in out:gmatch("[^\n]+") do
    counts[#counts + 1] = tonumber(line)
  end
  if #counts ~= #queries then
    error(("notmuch count --batch returned %d counts for %d queries"):format(#counts, #queries), 0)
  end
  return counts
end

function M.lastmod()
  return run({ "count", "--lastmod", "--", "*" }):match("^%d+\t(%S+\t%d+)")
end

function M.show(id)
  local found = shown(run({
    "show",
    "--format=json",
    "--include-html",
    "--entire-thread=false",
    "--exclude=false",
    "--",
    M.id_query(id),
  }))
  return found[1] or error(("message %s not found"):format(id), 0)
end

function M.part(id, part)
  return run({ "show", "--format=raw", "--part=" .. part, "--", M.id_query(id) }, { binary = true })
end

function M.raw(id)
  return run({ "show", "--format=raw", "--", M.id_query(id) }, { binary = true })
end

function M.files_by_id(ids)
  local files = {}
  for _, message in
    ipairs(shown(run({
      "show",
      "--format=json",
      "--body=false",
      "--entire-thread=false",
      "--exclude=false",
      "--",
      M.ids_query(ids),
    })))
  do
    files[message.id] = message.filename or {}
  end
  for _, id in ipairs(ids) do
    if not files[id] then
      error(("message %s is no longer in the notmuch database"):format(id), 0)
    end
  end
  return files
end

function M.addresses(query, output)
  return decode(run({
    "address",
    "--format=json",
    "--output=" .. output,
    "--output=count",
    "--deduplicate=address",
    "--",
    query,
  }))
end

function M.reply_headers(id, all)
  return decode(run({ "reply", "--format=json", "--reply-to=" .. (all and "all" or "sender"), "--", M.id_query(id) }))["reply-headers"]
end

function M.tag(ids, changes)
  local args = { "tag" }
  vim.list_extend(args, changes)
  vim.list_extend(args, { "--", M.ids_query(ids) })
  run(args)
end

function M.insert(folder, message, changes)
  local args = { "insert", "--folder=" .. folder }
  vim.list_extend(args, changes)
  run(args, { stdin = message, binary = true })
end

function M.reindex()
  run({ "new", "--quiet" })
end

local database

function M.database_path()
  if not database then
    database = vim.trim(run({ "config", "get", "database.path" }))
  end
  return database
end

return M
