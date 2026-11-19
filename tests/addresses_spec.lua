local addresses = require("email.addresses")
local format = require("email.format")

describe("token_start finds the address being typed on recipient headers only", function()
  eq({ 4, "jo" }, { addresses.token_start("To: jo", 6) })
  eq({ 15, "an" }, { addresses.token_start("Cc: a@b.c, bob,an", 17) })
  eq({ 10, "" }, { addresses.token_start("Reply-To: ", 10) })
  eq(nil, addresses.token_start("Subject: jo", 11))
  eq(nil, addresses.token_start("To: jo", 1))
end)

describe("rank merges by address, weights people we wrote to, and keeps the first name", function()
  local ranked = addresses.rank(
    { { address = "Ann@x.y", name = "", count = 1 } },
    { { address = "ann@x.y", name = "Ann A", count = 2 }, { address = "news@x.y", name = "News", count = 9 } }
  )
  eq({ { addr = "Ann@x.y", name = "Ann A", score = 12 }, { addr = "news@x.y", name = "News", score = 9 } }, ranked)
end)

describe("matches filters on name or address, case-insensitively, in rank order", function()
  local entries = { { addr = "ann@x.y", name = "Ann" }, { addr = "bob@x.y", name = "Bob Annson" }, { addr = "c@x.y" } }
  eq({ entries[1], entries[2] }, addresses.matches(entries, "ANN", 10))
  eq({ entries[1] }, addresses.matches(entries, "ann", 1))
end)

describe("folder_icon maps common folder names to roles", function()
  local icons = { inbox = "I", sent = "S", junk = "J", archive = "A", folder = "F", trash = "T", drafts = "D" }
  eq("I", format.folder_icon("INBOX", icons))
  eq("S", format.folder_icon("Sent Items", icons))
  eq("J", format.folder_icon("Junk Mail", icons))
  eq("A", format.folder_icon("All Mail", icons))
  eq("F", format.folder_icon("Receipts", icons))
end)

describe("images.extract rewrites references to short anchors and gives each its own row", function()
  local images = require("email.images")
  local lines, references = images.extract({
    "intro",
    "[![A](cid:a@x)](https://x.com) and ![](data:image/png;base64,AAAA)",
    "![T](<https://x.com/t.png>)",
  })
  eq({ "intro", "[![A](#image-1)](https://x.com) and ![](#image-2)", "", "![T](#image-3)" }, lines)
  eq({
    { alt = "A", source = "cid:a@x", row = 2 },
    { alt = "", source = "data:image/png;base64,AAAA", row = 3 },
    { alt = "T", source = "https://x.com/t.png", row = 4 },
  }, references)
end)
