local async = require("email.async")
local notmuch = require("email.notmuch")
local state = require("email.state")

local M = {}

local REFERENCE = "!%[([^%]]*)%]%(<?([^%s)>]+)>?%)"
local EXTENSIONS = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/jpg"] = "jpg",
  ["image/gif"] = "gif",
  ["image/webp"] = "webp",
  ["image/bmp"] = "bmp",
  ["image/avif"] = "avif",
  ["image/svg+xml"] = "svg",
}

local shown = {}

function M.extract(lines)
  local out, references = {}, {}
  for _, line in ipairs(lines) do
    local found = {}
    local rewritten = line:gsub(REFERENCE, function(alt, source)
      found[#found + 1] = { alt = alt, source = source }
      return ("![%s](#image-%d)"):format(alt, #references + #found)
    end)
    out[#out + 1] = rewritten
    for i, reference in ipairs(found) do
      if i > 1 then
        out[#out + 1] = ""
      end
      reference.row = #out
      references[#references + 1] = reference
    end
  end
  return out, references
end

local function strip_brackets(id)
  return (id:gsub("^<(.*)>$", "%1"))
end

function M.append_attachments(message, lines, references)
  local referenced = {}
  for _, reference in ipairs(references) do
    local cid = reference.source:match("^cid:(.+)$")
    if cid then
      referenced[strip_brackets(cid)] = true
    end
  end
  for _, image in ipairs(message.images) do
    if image.attachment and not (image.content_id and referenced[image.content_id]) then
      lines[#lines + 1] = ""
      lines[#lines + 1] = ("![%s](#image-%d)"):format(image.filename or "", #references + 1)
      references[#references + 1] = { alt = image.filename or "", source = "part:" .. image.part, row = #lines }
    end
  end
end

local function part_by_content_id(message, cid)
  cid = strip_brackets(cid)
  for _, image in ipairs(message.images) do
    if image.content_id == cid then
      return image
    end
  end
  return nil
end

local function part_by_id(message, id)
  for _, image in ipairs(message.images) do
    if image.part == id then
      return image
    end
  end
  return nil
end

local function write(dir, index, content_type, data)
  local extension = EXTENSIONS[content_type:lower()]
  if not extension then
    return nil
  end
  local path = ("%s/image-%d.%s"):format(dir, index, extension)
  local fd, err = io.open(path, "wb")
  if not fd then
    error(("write image %s: %s"):format(path, err), 0)
  end
  fd:write(data)
  fd:close()
  return path
end

function M.resolve(message, reference, dir, index, options)
  local source = reference.source
  local cid = source:match("^cid:(.+)$")
  local part = cid and part_by_content_id(message, cid)
    or source:match("^part:(%d+)$") and part_by_id(message, tonumber(source:match("^part:(%d+)$")))
  if part then
    return write(dir, index, part.content_type, notmuch.part(message.id, part.part))
  end
  local content_type, payload = source:match("^data:([^;,]+);base64,(.+)$")
  if content_type then
    local ok, data = pcall(vim.base64.decode, payload)
    if not ok then
      vim.notify(("email.nvim: image %d has an invalid data: URI (%s)"):format(index, data), vim.log.levels.WARN)
      return nil
    end
    return write(dir, index, content_type, data)
  end
  if options.remote and source:match("^https?://") then
    local path = ("%s/image-%d"):format(dir, index)
    async.checked({
      "curl",
      "--fail",
      "--silent",
      "--show-error",
      "--location",
      "--max-time",
      "20",
      "--output",
      path,
      source,
    })
    return path
  end
  return nil
end

function M.clear()
  for _, image in ipairs(shown) do
    image:clear()
  end
  shown = {}
end

function M.show(message, references, buf, win, first_row)
  M.clear()
  local options = state.config.images
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local api = require("image")
  for index, reference in ipairs(references) do
    local path = M.resolve(message, reference, dir, index, options)
    if not state.current or state.current.id ~= message.id or not vim.api.nvim_win_is_valid(win) then
      return
    end
    if path then
      local image = api.from_file(path, {
        window = win,
        buffer = buf,
        with_virtual_padding = true,
        inline = true,
        x = 0,
        y = first_row + reference.row - 1,
        max_width_window_percentage = options.max_width,
        max_height_window_percentage = options.max_height,
      })
      if image then
        image:render()
        shown[#shown + 1] = image
      end
    end
  end
end

return M
