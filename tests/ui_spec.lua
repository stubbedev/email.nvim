local composer = require("email.ui.composer")
local format = require("email.format")

describe("composer round-trips headers, attachments and body", function()
  local lines = composer.lines({
    headers = { From = "Me <me@x.y>", To = "you@x.y", Cc = "", Subject = "Hi", Bcc = "" },
    attach = { "/tmp/a.pdf" },
    body = { "line 1", "", "line 3" },
  })
  eq(
    { "From: Me <me@x.y>", "To: you@x.y", "Cc: ", "Subject: Hi", "Attach: /tmp/a.pdf", "", "line 1", "", "line 3" },
    lines
  )
  eq({
    headers = { From = "Me <me@x.y>", To = "you@x.y", Cc = "", Subject = "Hi" },
    attach = { "/tmp/a.pdf" },
    body = "line 1\n\nline 3",
  }, composer.parse(lines))
end)

describe("composer joins folded header lines and rejects unknown headers", function()
  eq("a@x.y, b@x.y", composer.parse({ "To: a@x.y,", "  b@x.y", "" }).headers.To)
  local ok, err = pcall(composer.parse, { "X-Foo: bar", "" })
  eq(false, ok)
  eq(true, err:find("unknown header", 1, true) ~= nil)
end)

describe("fit pads, truncates with an ellipsis and respects display width", function()
  eq("ab   ", format.fit("ab", 5))
  eq("abcd…", format.fit("abcdefgh", 5))
  eq(5, vim.fn.strdisplaywidth(format.fit("日本語テキスト", 5)))
end)

describe("date picks time, weekday, month-day or ISO date", function()
  local now = os.time({ year = 2026, month = 11, day = 19, hour = 15, min = 0 })
  eq("09:05", format.date(os.time({ year = 2026, month = 11, day = 19, hour = 9, min = 5 }), now))
  eq("Mon 10:00", format.date(os.time({ year = 2026, month = 11, day = 16, hour = 10, min = 0 }), now))
  eq("Feb 03", format.date(os.time({ year = 2026, month = 2, day = 3, hour = 10 }), now))
  eq("2024-02-03", format.date(os.time({ year = 2024, month = 2, day = 3, hour = 10 }), now))
end)

describe("row lays out status, sender, subject and a right-aligned date in the window width", function()
  local now = os.time({ year = 2026, month = 11, day = 19, hour = 15, min = 0 })
  local icons = { unread = "●", flagged = "★", replied = "↩", attachment = "@" }
  local line, highlights = format.row({
    id = "1",
    timestamp = os.time({ year = 2026, month = 11, day = 19, hour = 9, min = 5 }),
    tags = { unread = true, attachment = true },
    sender = "Jane Doe",
    headers = { Subject = "Hello\tthere" },
  }, 80, icons, now)
  eq(80, vim.fn.strdisplaywidth(line))
  eq(true, line:find("● @ Jane Doe", 1, true) ~= nil)
  eq(true, line:find("Hello there", 1, true) ~= nil)
  eq(true, line:find("09:05 $") ~= nil)
  eq("EmailUnread", highlights[1][3])
end)
