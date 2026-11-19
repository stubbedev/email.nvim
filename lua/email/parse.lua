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

local CALENDAR_TYPES = { ["text/calendar"] = true, ["application/ics"] = true }

local function collect(part, calendars, images)
  local ctype = content_type(part)
  if CALENDAR_TYPES[ctype] then
    calendars[#calendars + 1] = type(part.content) == "string" and { content = part.content } or { part = part.id }
  elseif ctype:sub(1, 6) == "image/" then
    local disposition = part["content-disposition"]
    images[#images + 1] = {
      part = part.id,
      content_type = ctype,
      content_id = part["content-id"] and (part["content-id"]:gsub("^<(.*)>$", "%1")),
      filename = part.filename,
      attachment = disposition == "attachment" or (part.filename ~= nil and disposition ~= "inline"),
    }
  end
  if type(part.content) == "table" then
    for _, child in ipairs(part.content) do
      if child["content-type"] then
        collect(child, calendars, images)
      end
    end
  end
end

local function tag_set(tags)
  local set = {}
  for _, tag in ipairs(tags or {}) do
    set[tag] = true
  end
  return set
end

function M.matched_ids(query)
  local ids, at = {}, 1
  query = query or ""
  while true do
    local start = query:find("id:", at, true)
    if not start then
      return ids
    end
    local rest = start + 3
    if query:sub(rest, rest) == '"' then
      local value, stop = {}, rest + 1
      while stop <= #query do
        local c = query:sub(stop, stop)
        if c == '"' and query:sub(stop + 1, stop + 1) == '"' then
          value[#value + 1] = '"'
          stop = stop + 2
        elseif c == '"' then
          break
        else
          value[#value + 1] = c
          stop = stop + 1
        end
      end
      ids[#ids + 1] = table.concat(value)
      at = stop + 1
    else
      local value = query:match("^(%S+)", rest)
      ids[#ids + 1] = value
      at = rest + #value
    end
  end
end

function M.thread(raw)
  local matched, others = (raw.authors or ""):match("^(.-)|(.*)$")
  local authors = matched and (vim.trim(matched) .. ", " .. vim.trim(others)) or (raw.authors or "")
  return {
    id = raw.thread,
    timestamp = raw.timestamp,
    tags = tag_set(raw.tags),
    authors = authors:gsub("^, ", ""):gsub(", $", ""),
    headers = { Subject = raw.subject or "" },
    total = raw.total,
    message_ids = M.matched_ids(raw.query and raw.query[1]),
  }
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
  message.blocks, message.attachments, message.calendars, message.images = {}, {}, {}, {}
  for _, part in ipairs(raw.body or {}) do
    walk(part, preference, message.blocks, message.attachments)
    collect(part, message.calendars, message.images)
  end
  return message
end

return M
