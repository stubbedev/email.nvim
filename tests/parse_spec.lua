local parse = require("email.parse")

local function message(body)
  return { id = "x", timestamp = 0, tags = { "unread" }, filename = { "/m/a" }, headers = {}, body = body }
end

describe("multipart/alternative picks the first preferred type", function()
  local m = parse.message(
    message({
      {
        id = 1,
        ["content-type"] = "multipart/alternative",
        content = {
          { id = 2, ["content-type"] = "text/plain", content = "plain" },
          { id = 3, ["content-type"] = "text/html", content = "<p>html</p>" },
        },
      },
    }),
    { "text/html", "text/plain" }
  )
  eq({ { kind = "text", content_type = "text/html", content = "<p>html</p>" } }, m.blocks)
  eq({}, m.attachments)
  eq(true, m.tags.unread)
end)

describe("multipart/related inside alternative counts as its root type", function()
  local m = parse.message(
    message({
      {
        id = 1,
        ["content-type"] = "multipart/alternative",
        content = {
          { id = 2, ["content-type"] = "text/plain", content = "plain" },
          {
            id = 3,
            ["content-type"] = "multipart/related",
            content = {
              { id = 4, ["content-type"] = "text/html", content = "<b>x</b>" },
              { id = 5, ["content-type"] = "image/png", filename = "logo.png", ["content-length"] = 10 },
            },
          },
        },
      },
    }),
    { "text/html", "text/plain" }
  )
  eq("text/html", m.blocks[1].content_type)
  eq({ { part = 5, filename = "logo.png", content_type = "image/png", size = 10 } }, m.attachments)
end)

describe("signed messages show the signed content and skip the signature", function()
  local m = parse.message(
    message({
      {
        id = 1,
        ["content-type"] = "multipart/signed",
        content = {
          { id = 2, ["content-type"] = "text/plain", content = "signed text" },
          { id = 3, ["content-type"] = "application/pkcs7-signature", filename = "smime.p7s" },
        },
      },
    }),
    { "text/html", "text/plain" }
  )
  eq({ { kind = "text", content_type = "text/plain", content = "signed text" } }, m.blocks)
  eq({}, m.attachments)
end)

describe("attached messages render their headers and body inline", function()
  local m = parse.message(
    message({
      {
        id = 1,
        ["content-type"] = "message/rfc822",
        content = {
          {
            headers = { From = "a@b.c", Subject = "inner" },
            body = { { id = 2, ["content-type"] = "text/plain", content = "inner body" } },
          },
        },
      },
    }),
    { "text/plain" }
  )
  eq("headers", m.blocks[1].kind)
  eq("inner body", m.blocks[2].content)
end)

describe("nameless inline resources are not listed as attachments", function()
  local m = parse.message(
    message({
      {
        id = 1,
        ["content-type"] = "multipart/related",
        content = {
          { id = 2, ["content-type"] = "text/html", content = "<img src=cid:a>" },
          { id = 3, ["content-type"] = "image/png" },
        },
      },
    }),
    { "text/html" }
  )
  eq({}, m.attachments)
end)

describe("text parts with attachment disposition are attachments", function()
  local m = parse.message(
    message({
      {
        id = 1,
        ["content-type"] = "text/csv",
        ["content-disposition"] = "attachment",
        filename = "a.csv",
        content = "1,2",
      },
    }),
    { "text/plain" }
  )
  eq({}, m.blocks)
  eq("a.csv", m.attachments[1].filename)
end)
