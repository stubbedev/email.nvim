local mime = require("email.mime")

describe("parse_addresses splits on commas outside quotes and angle brackets", function()
  eq({
    { name = "Doe, Jane", addr = "jane@example.com" },
    { addr = "bob@example.com" },
    { name = "Ann", addr = "ann@example.com" },
  }, mime.parse_addresses('"Doe, Jane" <jane@example.com>, bob@example.com,Ann <ann@example.com>'))
end)

describe("parse_addresses unescapes quoted names", function()
  eq({ { name = 'A "B" C', addr = "a@b.c" } }, mime.parse_addresses([["A \"B\" C" <a@b.c>]]))
end)

describe("encode_word leaves ASCII alone and splits UTF-8 on character boundaries", function()
  eq("Hello", mime.encode_word("Hello"))
  local subject = string.rep("æøå", 20)
  local encoded = mime.encode_word(subject)
  local decoded = {}
  for chunk in encoded:gmatch("=%?UTF%-8%?B%?(.-)%?=") do
    decoded[#decoded + 1] = vim.base64.decode(chunk)
    eq(true, vim.str_utf_pos(decoded[#decoded]) ~= nil)
    eq(true, #("=?UTF-8?B?" .. chunk .. "?=") <= 75)
  end
  eq(subject, table.concat(decoded))
end)

describe("format_address quotes specials and encodes non-ASCII names", function()
  eq('"Doe, Jane" <j@x.y>', mime.format_address({ name = "Doe, Jane", addr = "j@x.y" }))
  eq(
    "=?UTF-8?B?" .. vim.base64.encode("Søren") .. "?= <s@x.y>",
    mime.format_address({ name = "Søren", addr = "s@x.y" })
  )
  eq("plain@x.y", mime.format_address({ addr = "plain@x.y" }))
end)

describe("date is RFC 5322 in UTC regardless of locale", function()
  eq("Thu, 19 Nov 2026 12:00:00 +0000", mime.date(1795089600))
end)

describe("quoted_printable escapes non-ASCII, '=' and trailing space, and soft-wraps at 76", function()
  eq("caf=C3=A9 =3D 1=20", mime.quoted_printable("café = 1 "))
  local long = mime.quoted_printable(string.rep("a", 100))
  for line in (long .. "\n"):gmatch("(.-)\n") do
    eq(true, #line <= 76)
  end
  eq(string.rep("a", 100), (long:gsub("=\n", "")))
end)

describe("build emits a single text part when there are no attachments", function()
  local out = mime.build({
    headers = { { "From", "Me <me@x.y>" }, { "Subject", "Hi" } },
    body = "hello",
    attachments = {},
    alternatives = {},
    boundary = "B",
  })
  eq(
    "From: Me <me@x.y>\nSubject: Hi\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n"
      .. "Content-Transfer-Encoding: 7bit\n\nhello\n",
    out
  )
end)

describe("build wraps attachments in multipart/mixed with base64 bodies", function()
  local out = mime.build({
    headers = { { "Subject", "Fil" } },
    body = "se vedhæftet",
    attachments = { { filename = "rapport ø.pdf", data = "PDFDATA" } },
    alternatives = {},
    boundary = "XYZ",
  })
  eq(true, out:find('Content-Type: multipart/mixed; boundary="XYZ"', 1, true) ~= nil)
  eq(true, out:find("Content-Transfer-Encoding: quoted-printable\n\nse vedh=C3=A6ftet\n", 1, true) ~= nil)
  eq(true, out:find("filename*=UTF-8''rapport%20%C3%B8.pdf", 1, true) ~= nil)
  eq(true, out:find(vim.base64.encode("PDFDATA"), 1, true) ~= nil)
  eq(true, out:find("\n%-%-XYZ%-%-\n$") ~= nil)
end)

describe("build nests a multipart/alternative calendar part inside multipart/mixed", function()
  local out = mime.build({
    headers = { { "Subject", "Accepted: Sync" } },
    body = "ok",
    attachments = { { filename = "a.txt", data = "A" } },
    alternatives = { { content_type = "text/calendar; charset=utf-8; method=REPLY", data = "BEGIN:VCALENDAR\r\n" } },
    boundary = "M",
  })
  eq(true, out:find('Content-Type: multipart/mixed; boundary="M"', 1, true) ~= nil)
  eq(true, out:find('\n--M\nContent-Type: multipart/alternative; boundary="M.alt"\n\n--M.alt\n', 1, true) ~= nil)
  eq(
    true,
    out:find("Content-Type: text/calendar; charset=utf-8; method=REPLY\nContent-Transfer-Encoding: base64", 1, true)
      ~= nil
  )
  eq(true, out:find(vim.base64.encode("BEGIN:VCALENDAR\r\n"), 1, true) ~= nil)
  eq(true, out:find("\n--M.alt--\n", 1, true) ~= nil)
  eq(true, out:find("\n--M--\n$") ~= nil)
end)

describe("display_address quotes specials but keeps UTF-8 names readable", function()
  eq("Søren <s@x.y>", mime.display_address({ name = "Søren", addr = "s@x.y" }))
  eq('"Doe, Jane" <j@x.y>', mime.display_address({ name = "Doe, Jane", addr = "j@x.y" }))
end)
