local images = require("email.images")

describe("an image on the last line gets a line after it, so the cursor can scroll past it", function()
  local last = { lines = { "text", "I pic" }, images = { { row = 2, alt = "pic", source = "cid:a" } } }
  images.pad_end(last)
  eq({ "text", "I pic", "" }, last.lines)
  local middle = { lines = { "I pic", "text" }, images = { { row = 1, alt = "pic", source = "cid:a" } } }
  images.pad_end(middle)
  eq({ "I pic", "text" }, middle.lines)
end)
