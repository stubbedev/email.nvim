local M = {}

function M.split(path, root)
  local prefix = root .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local folder, sub, name = path:sub(#prefix + 1):match("^(.+)/([a-z]+)/([^/]+)$")
  if sub ~= "cur" and sub ~= "new" then
    return nil
  end
  return folder, name
end

function M.target_name(name)
  local base, info = name:match("^(.-)(:2,.*)$")
  if not base then
    base, info = name, ":2,"
  end
  return (base:gsub(",U=%d+", "")) .. info
end

local function checked(ok, err, what)
  if not ok then
    error(what .. ": " .. tostring(err), 0)
  end
end

function M.move(files, root, target)
  local sources, in_target = {}, false
  for _, file in ipairs(files) do
    local folder = M.split(file, root)
    if folder == target then
      in_target = true
    elseif folder then
      sources[#sources + 1] = file
    end
  end
  if #sources == 0 then
    if in_target then
      return
    end
    error(("no file of the message lives under %s"):format(root), 0)
  end
  if not in_target then
    local first = table.remove(sources, 1)
    local _, name = M.split(first, root)
    local dest = table.concat({ root, target, "cur", M.target_name(name) }, "/")
    local ok, err = vim.uv.fs_rename(first, dest)
    checked(ok, err, ("move %s to %s"):format(first, dest))
  end
  for _, file in ipairs(sources) do
    local ok, err = vim.uv.fs_unlink(file)
    checked(ok, err, "remove " .. file)
  end
end

function M.unlink(files, root)
  local removed = 0
  for _, file in ipairs(files) do
    if M.split(file, root) then
      local ok, err = vim.uv.fs_unlink(file)
      checked(ok, err, "remove " .. file)
      removed = removed + 1
    end
  end
  if removed == 0 then
    error(("no file of the message lives under %s"):format(root), 0)
  end
end

function M.folders(root)
  local out = {}
  for name, kind in vim.fs.dir(root, { depth = 4 }) do
    if kind == "directory" and vim.fs.basename(name) == "cur" and name ~= "cur" then
      out[#out + 1] = vim.fs.dirname(name)
    end
  end
  table.sort(out)
  return out
end

return M
