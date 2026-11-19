local M = {}

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local ADDRESS_HEADERS = { From = true, To = true, Cc = true, Bcc = true, ["Reply-To"] = true }
local ENCODED_WORD_BYTES = 45

local function is_ascii(s)
  return not s:find("[\128-\255]")
end

local function unquote(name)
  local inner = name:match('^"(.*)"$')
  if not inner then
    return name
  end
  return (inner:gsub("\\(.)", "%1"))
end

local function parse_mailbox(s)
  local name, addr = s:match("^(.-)%s*<([^>]*)>$")
  if not addr then
    return { addr = s }
  end
  name = unquote(vim.trim(name))
  return { name = name ~= "" and name or nil, addr = vim.trim(addr) }
end

function M.parse_addresses(s)
  local out, start, quoted, angle, escaped = {}, 1, false, false, false
  local function flush(stop)
    local item = vim.trim(s:sub(start, stop))
    if item ~= "" then
      out[#out + 1] = parse_mailbox(item)
    end
  end
  for i = 1, #s do
    local c = s:sub(i, i)
    if escaped then
      escaped = false
    elseif c == "\\" and quoted then
      escaped = true
    elseif c == '"' then
      quoted = not quoted
    elseif c == "<" and not quoted then
      angle = true
    elseif c == ">" and not quoted then
      angle = false
    elseif c == "," and not quoted and not angle then
      flush(i - 1)
      start = i + 1
    end
  end
  flush(#s)
  return out
end

function M.encode_word(s)
  if is_ascii(s) then
    return s
  end
  local chunks, i, n = {}, 1, #s
  while i <= n do
    local j = math.min(i + ENCODED_WORD_BYTES - 1, n)
    while j < n and s:byte(j + 1) >= 0x80 and s:byte(j + 1) < 0xC0 do
      j = j - 1
    end
    chunks[#chunks + 1] = "=?UTF-8?B?" .. vim.base64.encode(s:sub(i, j)) .. "?="
    i = j + 1
  end
  return table.concat(chunks, "\n ")
end

function M.format_address(address)
  if not address.name then
    return address.addr
  end
  local name = address.name
  if not is_ascii(name) then
    name = M.encode_word(name)
  elseif name:find('[()<>%[%]:;@\\,."]') then
    name = '"' .. name:gsub('(["\\])', "\\%1") .. '"'
  end
  return name .. " <" .. address.addr .. ">"
end

function M.header_value(name, value)
  if ADDRESS_HEADERS[name] then
    local formatted = {}
    for i, address in ipairs(M.parse_addresses(value)) do
      formatted[i] = M.format_address(address)
    end
    return table.concat(formatted, ",\n ")
  end
  if name == "Subject" then
    return M.encode_word(value)
  end
  return value
end

function M.date(epoch)
  local t = os.date("!*t", epoch)
  return ("%s, %02d %s %04d %02d:%02d:%02d +0000"):format(
    DAYS[t.wday],
    t.day,
    MONTHS[t.month],
    t.year,
    t.hour,
    t.min,
    t.sec
  )
end

function M.message_id(epoch, unique, domain)
  return ("<%d.%s@%s>"):format(epoch, unique, domain)
end

local function quoted_printable_line(line)
  local pieces, width = {}, 0
  for i = 1, #line do
    local b = line:byte(i)
    local token
    if (b >= 33 and b <= 126 and b ~= 61) or ((b == 32 or b == 9) and i < #line) then
      token = string.char(b)
    else
      token = ("=%02X"):format(b)
    end
    if width + #token > 75 then
      pieces[#pieces + 1] = "=\n"
      width = 0
    end
    pieces[#pieces + 1] = token
    width = width + #token
  end
  return table.concat(pieces)
end

function M.quoted_printable(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = quoted_printable_line(line)
  end
  return table.concat(lines, "\n")
end

local function needs_encoding(text)
  if not is_ascii(text) then
    return true
  end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if #line > 998 then
      return true
    end
  end
  return false
end

local function text_part(body)
  if not body:find("\n$") then
    body = body .. "\n"
  end
  if needs_encoding(body) then
    return {
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: quoted-printable",
    },
      M.quoted_printable(body)
  end
  return { "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 7bit" }, body
end

local function filename_param(name)
  if is_ascii(name) and not name:find('[%c"\\]') then
    return ('filename="%s"'):format(name)
  end
  return "filename*=UTF-8''" .. (name:gsub("[^%w%.%-_~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

local function base64_lines(data)
  local encoded, lines = vim.base64.encode(data), {}
  for i = 1, #encoded, 76 do
    lines[#lines + 1] = encoded:sub(i, i + 75)
  end
  return table.concat(lines, "\n")
end

function M.build(message)
  local out = {}
  for _, header in ipairs(message.headers) do
    out[#out + 1] = header[1] .. ": " .. M.header_value(header[1], header[2])
  end
  out[#out + 1] = "MIME-Version: 1.0"
  local part_headers, body = text_part(message.body)
  if #message.attachments == 0 then
    vim.list_extend(out, part_headers)
    out[#out + 1] = ""
    out[#out + 1] = body
    return table.concat(out, "\n")
  end
  local boundary = message.boundary
  out[#out + 1] = ('Content-Type: multipart/mixed; boundary="%s"'):format(boundary)
  out[#out + 1] = ""
  out[#out + 1] = "--" .. boundary
  vim.list_extend(out, part_headers)
  out[#out + 1] = ""
  out[#out + 1] = body
  for _, attachment in ipairs(message.attachments) do
    out[#out + 1] = "--" .. boundary
    out[#out + 1] = "Content-Type: application/octet-stream"
    out[#out + 1] = "Content-Disposition: attachment; " .. filename_param(attachment.filename)
    out[#out + 1] = "Content-Transfer-Encoding: base64"
    out[#out + 1] = ""
    out[#out + 1] = base64_lines(attachment.data)
  end
  out[#out + 1] = "--" .. boundary .. "--"
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

return M
