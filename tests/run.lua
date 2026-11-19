local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local failures, passed = 0, 0

local function describe(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures = failures + 1
    io.stderr:write(("FAIL %s\n%s\n"):format(name, err))
  end
end

_G.describe = describe
_G.eq = function(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

for name, kind in vim.fs.dir(root .. "/tests") do
  if kind == "file" and name:match("_spec%.lua$") then
    dofile(root .. "/tests/" .. name)
  end
end

io.stdout:write(("%d passed, %d failed\n"):format(passed, failures))
os.exit(failures == 0 and 0 or 1)
