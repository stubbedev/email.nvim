local M = {}

local function content_type(part)
  return (part["content-type"] or "application/octet-stream"):lower()
end

local function effective_type(part)
  if content_type(part) == "multipart/related" and type(part.content) == "table" and part.content[1] then
    return effective_type(part.content[1])
  end
  return content_type(part)
end

local function choose_alternative(parts, preference)
  for _, wanted in ipairs(preference) do
    for _, part in ipairs(parts) do
      if effective_type(part) == wanted then
        return part
      end
    end
  end
  return parts[#parts]
end

local function walk(part, preference, blocks, attachments)
  local ctype = content_type(part)
  local children = type(part.content) == "table" and part.content or {}
  if ctype == "multipart/alternative" and #children > 0 then
    walk(choose_alternative(children, preference), preference, blocks, attachments)
  elseif ctype == "multipart/signed" and #children > 0 then
    walk(children[1], preference, blocks, attachments)
  elseif ctype:sub(1, 10) == "multipart/" then
    for _, child in ipairs(children) do
      walk(child, preference, blocks, attachments)
    end
  elseif ctype == "message/rfc822" and #children > 0 then
    for _, inner in ipairs(children) do
      blocks[#blocks + 1] = { kind = "headers", headers = inner.headers or {} }
      for _, child in ipairs(inner.body or {}) do
        walk(child, preference, blocks, attachments)
      end
    end
  elseif
    ctype:sub(1, 5) == "text/"
    and part["content-disposition"] ~= "attachment"
    and type(part.content) == "string"
  then
    blocks[#blocks + 1] = { kind = "text", content_type = ctype, content = part.content }
  elseif part.filename or part["content-disposition"] == "attachment" then
    attachments[#attachments + 1] = {
      part = part.id,
      filename = part.filename or ("part-" .. part.id),
      content_type = ctype,
      size = part["content-length"],
    }
  end
end

local function tag_set(tags)
  local set = {}
  for _, tag in ipairs(tags or {}) do
    set[tag] = true
  end
  return set
end

function M.summary(raw)
  return {
    id = raw.id,
    timestamp = raw.timestamp,
    tags = tag_set(raw.tags),
    files = raw.filename or {},
    headers = raw.headers or {},
  }
end

function M.message(raw, preference)
  local message = M.summary(raw)
  message.blocks, message.attachments = {}, {}
  for _, part in ipairs(raw.body or {}) do
    walk(part, preference, message.blocks, message.attachments)
  end
  return message
end

return M
