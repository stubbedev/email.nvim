local M = {}

local steppers = setmetatable({}, { __mode = "k" })

local function pack(...)
  return { n = select("#", ...), ... }
end

function M.run(fn, ...)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      vim.notify("email.nvim: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  steppers[co] = step
  step(...)
end

function M.await(start)
  local co = coroutine.running()
  local step = co and steppers[co]
  if not step then
    error("email.nvim: await called outside async.run", 2)
  end
  local yielded, early = false, nil
  start(function(...)
    local args = pack(...)
    if yielded then
      vim.schedule(function()
        step(unpack(args, 1, args.n))
      end)
    else
      early = args
    end
  end)
  if early then
    return unpack(early, 1, early.n)
  end
  yielded = true
  return coroutine.yield()
end

function M.mutex()
  local held, waiting = false, {}
  return function(fn)
    if held then
      M.await(function(resolve)
        waiting[#waiting + 1] = resolve
      end)
    else
      held = true
    end
    local result = pack(pcall(fn))
    local next_waiter = table.remove(waiting, 1)
    if next_waiter then
      next_waiter()
    else
      held = false
    end
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2, result.n)
  end
end

function M.system(cmd, opts)
  return M.await(function(resolve)
    vim.system(cmd, opts or {}, resolve)
  end)
end

function M.checked(cmd, opts)
  local res = M.system(cmd, opts)
  if res.code ~= 0 then
    error(("`%s` failed (exit %d): %s"):format(table.concat(cmd, " "), res.code, vim.trim(res.stderr or "")), 0)
  end
  return res.stdout or ""
end

function M.input(opts)
  return M.await(function(resolve)
    vim.ui.input(opts, resolve)
  end)
end

function M.select(items, opts)
  return M.await(function(resolve)
    vim.ui.select(items, opts, resolve)
  end)
end

return M
