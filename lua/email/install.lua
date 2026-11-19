local async = require("email.async")

local M = {}

local RELEASES = "https://github.com/stubbedev/email.nvim/releases/download"
local PLATFORMS = {
  Linux = { x86_64 = "linux-amd64", aarch64 = "linux-arm64", arm64 = "linux-arm64" },
  Darwin = { arm64 = "darwin-arm64", aarch64 = "darwin-arm64" },
}

local installing = async.mutex()

function M.platform()
  local uname = vim.uv.os_uname()
  local platform = (PLATFORMS[uname.sysname] or {})[uname.machine]
  if not platform then
    error(
      ("email.nvim has no prebuilt engine for %s/%s; build it with `go build -o bin/email-engine ./cmd/email-engine` in the engine directory, or set `engine` to its path"):format(
        uname.sysname,
        uname.machine
      ),
      0
    )
  end
  return platform
end

function M.path(version)
  return ("%s/email.nvim/email-engine-%s"):format(vim.fn.stdpath("data"), version)
end

function M.checksum(sums, asset)
  for line in sums:gmatch("[^\n]+") do
    local sum, name = line:match("^(%x+)%s+%*?(%S+)$")
    if name == asset then
      return sum:lower()
    end
  end
  error(("the release checksums list no %s"):format(asset), 0)
end

local function fetch(url, out)
  async.checked({
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--max-time",
    "120",
    "--output",
    out,
    url,
  })
end

local function read(path)
  local fd = assert(io.open(path, "rb"))
  local data = fd:read("*a")
  fd:close()
  return data
end

local function download(version, path)
  local asset = "email-engine-" .. M.platform()
  local base = ("%s/v%s/"):format(RELEASES, version)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".download"
  local sums = path .. ".sha256sums"
  vim.notify(("email.nvim: downloading email-engine %s (%s)"):format(version, asset))
  fetch(base .. "sha256sums.txt", sums)
  fetch(base .. asset, tmp)
  local want = M.checksum(read(sums), asset)
  os.remove(sums)
  local got = vim.fn.sha256(read(tmp))
  if got ~= want then
    os.remove(tmp)
    error(("email-engine %s download is corrupt: sha256 %s, expected %s"):format(version, got, want), 0)
  end
  local ok, err = vim.uv.fs_chmod(tmp, tonumber("755", 8))
  if not ok then
    error(("chmod %s: %s"):format(tmp, err), 0)
  end
  ok, err = vim.uv.fs_rename(tmp, path)
  if not ok then
    error(("install %s: %s"):format(path, err), 0)
  end
end

function M.ensure(version)
  local path = M.path(version)
  installing(function()
    if not vim.uv.fs_stat(path) then
      download(version, path)
    end
  end)
  return path
end

return M
