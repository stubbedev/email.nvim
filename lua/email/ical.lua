local M = {}

local MAX_OCTETS = 75
local COPIED = { "UID", "SEQUENCE", "RECURRENCE-ID", "DTSTART", "DTEND", "DURATION", "SUMMARY", "ORGANIZER" }

function M.unfold(text)
  local unfolded = (text:gsub("\r\n", "\n"):gsub("\n[ \t]", ""))
  local lines = {}
  for line in (unfolded .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("%s+$", "")
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

local function split_unquoted(s, sep)
  local parts, start, quoted = {}, 1, false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      quoted = not quoted
    elseif c == sep and not quoted then
      parts[#parts + 1] = s:sub(start, i - 1)
      start = i + 1
    end
  end
  parts[#parts + 1] = s:sub(start)
  return parts
end

function M.property(line)
  local quoted, colon = false, nil
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == '"' then
      quoted = not quoted
    elseif c == ":" and not quoted then
      colon = i
      break
    end
  end
  if not colon then
    return nil
  end
  local parts = split_unquoted(line:sub(1, colon - 1), ";")
  local property = { name = parts[1]:upper(), params = {}, order = {}, value = line:sub(colon + 1), raw = line }
  for i = 2, #parts do
    local key, value = parts[i]:match("^([^=]+)=(.*)$")
    if key then
      key = key:upper()
      property.params[key] = value
      property.order[#property.order + 1] = key
    end
  end
  return property
end

function M.parse(text)
  local calendar = { timezones = {} }
  local stack, timezone = {}, nil
  for _, line in ipairs(M.unfold(text)) do
    local begin = line:match("^BEGIN:(.+)$")
    local finish = line:match("^END:(.+)$")
    local top = stack[#stack]
    if timezone then
      timezone[#timezone + 1] = line
    end
    if begin then
      begin = begin:upper()
      stack[#stack + 1] = begin
      if begin == "VTIMEZONE" and #stack == 2 then
        timezone = { line }
      elseif begin == "VEVENT" and #stack == 2 and not calendar.event then
        calendar.event = { props = {}, attendees = {} }
      end
    elseif finish then
      if finish:upper() == "VTIMEZONE" and timezone and #stack == 2 then
        calendar.timezones[#calendar.timezones + 1] = timezone
        timezone = nil
      end
      stack[#stack] = nil
    else
      local property = M.property(line)
      if property and top == "VCALENDAR" and property.name == "METHOD" then
        calendar.method = property.value:upper()
      elseif property and top == "VEVENT" and #stack == 2 and calendar.event and not calendar.event.done then
        if property.name == "ATTENDEE" then
          calendar.event.attendees[#calendar.event.attendees + 1] = property
        elseif not calendar.event.props[property.name] then
          calendar.event.props[property.name] = property
        end
      end
    end
    if finish and finish:upper() == "VEVENT" and calendar.event then
      calendar.event.done = true
    end
  end
  return calendar
end

function M.mailto(value)
  return value:match("^[Mm][Aa][Ii][Ll][Tt][Oo]:(.+)$") or value
end

function M.unescape(value)
  return (value:gsub("\\[nN]", " "):gsub("\\([,;\\])", "%1"))
end

function M.summary(calendar)
  local summary = calendar.event and calendar.event.props.SUMMARY
  return summary and M.unescape(summary.value) or nil
end

local function serialize(name, order, params, value)
  local parts = { name }
  for _, key in ipairs(order) do
    parts[#parts + 1] = key .. "=" .. params[key]
  end
  return table.concat(parts, ";") .. ":" .. value
end

function M.fold(line)
  local out = {}
  while #line > MAX_OCTETS do
    local cut = MAX_OCTETS
    while cut > 1 and line:byte(cut + 1) >= 0x80 and line:byte(cut + 1) < 0xC0 do
      cut = cut - 1
    end
    out[#out + 1] = line:sub(1, cut)
    line = " " .. line:sub(cut + 1)
  end
  out[#out + 1] = line
  return table.concat(out, "\r\n")
end

local function attendee_line(event, address, name, partstat)
  for _, attendee in ipairs(event.attendees) do
    if M.mailto(attendee.value):lower() == address:lower() then
      local order, params = {}, {}
      for _, key in ipairs(attendee.order) do
        if key ~= "PARTSTAT" and key ~= "RSVP" then
          order[#order + 1] = key
          params[key] = attendee.params[key]
        end
      end
      order[#order + 1] = "PARTSTAT"
      params.PARTSTAT = partstat
      return serialize("ATTENDEE", order, params, attendee.value)
    end
  end
  local order, params = { "PARTSTAT" }, { PARTSTAT = partstat }
  if name then
    order[#order + 1] = "CN"
    params.CN = '"' .. name:gsub('"', "") .. '"'
  end
  return serialize("ATTENDEE", order, params, "mailto:" .. address)
end

function M.reply(calendar, address, name, partstat, now)
  local event = calendar.event or error("the invite has no VEVENT", 0)
  if not event.props.UID then
    error("the invite has no UID", 0)
  end
  local lines = { "BEGIN:VCALENDAR", "PRODID:-//email.nvim//EN", "VERSION:2.0", "METHOD:REPLY" }
  for _, timezone in ipairs(calendar.timezones) do
    vim.list_extend(lines, timezone)
  end
  lines[#lines + 1] = "BEGIN:VEVENT"
  for _, key in ipairs(COPIED) do
    if event.props[key] then
      lines[#lines + 1] = event.props[key].raw
    end
  end
  lines[#lines + 1] = "DTSTAMP:" .. os.date("!%Y%m%dT%H%M%SZ", now)
  lines[#lines + 1] = attendee_line(event, address, name, partstat)
  lines[#lines + 1] = "END:VEVENT"
  lines[#lines + 1] = "END:VCALENDAR"
  for i, line in ipairs(lines) do
    lines[i] = M.fold(line)
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

return M
