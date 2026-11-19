local ical = require("email.ical")

local INVITE = table.concat({
  "BEGIN:VCALENDAR",
  "METHOD:REQUEST",
  "BEGIN:VTIMEZONE",
  "TZID:Europe/Copenhagen",
  "BEGIN:STANDARD",
  "TZOFFSETFROM:+0200",
  "TZOFFSETTO:+0100",
  "END:STANDARD",
  "END:VTIMEZONE",
  "BEGIN:VEVENT",
  "UID:abc-123",
  "SEQUENCE:2",
  "DTSTART;TZID=Europe/Copenhagen:20261120T100000",
  "DTEND;TZID=Europe/Copenhagen:20261120T110000",
  "SUMMARY:Team sync\\, weekly",
  'ORGANIZER;CN="Org, Anne":mailto:org@example.org',
  "ATTENDEE;CN=Test User;RSVP=TRUE;PARTSTAT=NEEDS-ACTION;ROLE=REQ-PARTICIPANT:mai",
  " lto:ME@example.com",
  "BEGIN:VALARM",
  "TRIGGER:-PT15M",
  "SUMMARY:alarm",
  "END:VALARM",
  "END:VEVENT",
  "END:VCALENDAR",
}, "\r\n")

describe("parse unfolds lines, reads METHOD and the first VEVENT, skips VALARM", function()
  local calendar = ical.parse(INVITE)
  eq("REQUEST", calendar.method)
  eq("Team sync, weekly", ical.summary(calendar))
  eq("abc-123", calendar.event.props.UID.value)
  eq("mailto:ME@example.com", calendar.event.attendees[1].value)
  eq('"Org, Anne"', calendar.event.props.ORGANIZER.params.CN)
  eq(1, #calendar.timezones)
  eq("END:VTIMEZONE", calendar.timezones[1][#calendar.timezones[1]])
end)

describe("reply answers as the matching attendee with the new PARTSTAT", function()
  local reply = ical.reply(ical.parse(INVITE), "me@example.com", "Test User", "ACCEPTED", 1795089600)
  eq(true, reply:find("METHOD:REPLY\r\n", 1, true) ~= nil)
  eq(true, reply:find("BEGIN:VTIMEZONE\r\nTZID:Europe/Copenhagen", 1, true) ~= nil)
  eq(true, reply:find("UID:abc-123\r\nSEQUENCE:2\r\n", 1, true) ~= nil)
  eq(true, reply:find("DTSTAMP:20261119T120000Z\r\n", 1, true) ~= nil)
  local unfolded = reply:gsub("\r\n ", "")
  eq(
    true,
    unfolded:find("ATTENDEE;CN=Test User;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:ME@example.com", 1, true) ~= nil
  )
  eq(nil, reply:find("RSVP", 1, true))
  eq(nil, reply:find("VALARM", 1, true))
  for line in reply:gmatch("(.-)\r\n") do
    eq(true, #line <= 75)
  end
end)

describe("reply adds an attendee when the invite does not list us", function()
  local reply = ical.reply(ical.parse(INVITE), "other@example.com", "Other", "DECLINED", 0)
  eq(
    true,
    reply:gsub("\r\n ", ""):find('ATTENDEE;PARTSTAT=DECLINED;CN="Other":mailto:other@example.com', 1, true) ~= nil
  )
end)

describe("fold splits on UTF-8 boundaries", function()
  local folded = ical.fold("SUMMARY:" .. string.rep("æ", 60))
  for line in (folded .. "\r\n"):gmatch("(.-)\r\n") do
    eq(true, #line <= 75)
    eq(true, vim.str_utf_pos(line) ~= nil)
  end
  eq("SUMMARY:" .. string.rep("æ", 60), (folded:gsub("\r\n ", "")))
end)
