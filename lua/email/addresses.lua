local async = require("email.async")
local engine = require("email.engine")

local M = {}

local COMPLETABLE = { to = true, cc = true, bcc = true, ["reply-to"] = true }
local MAX_OMNI_ITEMS = 50

local cache
local loading = async.mutex()

local function harvest()
  return loading(function()
    cache = engine.addresses()
    return cache
  end)
end

function M.load()
  return cache or harvest()
end

function M.refresh()
  async.run(harvest)
end

function M.cached()
  return cache
end

function M.token_start(line, col)
  local name, value_start = line:match("^([%w-]+):%s*()")
  if not name or not COMPLETABLE[name:lower()] or col < value_start - 1 then
    return nil
  end
  local before = line:sub(1, col)
  local start = value_start
  local comma = before:find(",[^,]*$")
  if comma and comma >= value_start then
    start = comma + 1
  end
  while before:sub(start, start) == " " do
    start = start + 1
  end
  return start - 1, before:sub(start)
end

function M.at_cursor(buf, row, col)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, row, false)
  for i = 1, row - 1 do
    if lines[i] == "" then
      return nil
    end
  end
  return M.token_start(lines[row] or "", col)
end

function M.matches(entries, query, limit)
  query = query:lower()
  local out = {}
  for _, entry in ipairs(entries) do
    if entry.addr:lower():find(query, 1, true) or (entry.name and entry.name:lower():find(query, 1, true)) then
      out[#out + 1] = entry
      if #out == limit then
        break
      end
    end
  end
  return out
end

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    return M.at_cursor(vim.api.nvim_get_current_buf(), row, col) or -3
  end
  if not cache then
    M.refresh()
    return {}
  end
  local items = {}
  for i, entry in ipairs(M.matches(cache, base, MAX_OMNI_ITEMS)) do
    items[i] = { word = entry.display, menu = "[email]" }
  end
  return items
end

return M
