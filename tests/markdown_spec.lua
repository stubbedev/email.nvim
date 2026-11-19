local markdown = require("email.markdown")

local opts = {
  headings = { "H1 ", "H2 " },
  bullets = { "*", "-" },
  quote = "|",
  link = "L ",
  email = "E ",
  image = "I ",
}

local function md(lines, width, extra)
  return markdown.render(
    { { lines = lines, markdown = true } },
    width or 40,
    vim.tbl_extend("force", opts, extra or {})
  )
end

local function spans_on(doc, row)
  local out = {}
  for _, hl in ipairs(doc.highlights) do
    if hl[1] == row then
      out[#out + 1] = { doc.lines[row]:sub(hl[2] + 1, hl[3]), hl[4] }
    end
  end
  return out
end

describe("links render as their label with the url kept aside", function()
  local doc = md({ "See [the docs](https://x.com/a_b) and [me](mailto:a@b.c)." })
  eq({ "See L the docs and E me." }, doc.lines)
  eq({
    { row = 1, start_col = 4, end_col = 14, url = "https://x.com/a_b" },
    { row = 1, start_col = 19, end_col = 23, url = "mailto:a@b.c" },
  }, doc.links)
  eq({ { "L the docs", "EmailLink" }, { "E me", "EmailLink" } }, spans_on(doc, 1))
end)

describe("emphasis, code and escapes lose their markers", function()
  local doc = md({ "**bold** *it* `co*de` a \\* b \\_c\\_ <https://y.org>" })
  eq({ "bold it co*de a * b _c_ https://y.org" }, doc.lines)
  eq(
    { { "bold", "EmailStrong" }, { "it", "EmailEmph" }, { "co*de", "EmailCode" }, { "https://y.org", "EmailLink" } },
    spans_on(doc, 1)
  )
  eq("https://y.org", doc.links[1].url)
end)

describe("a linked image shows its alt text and records the image on its row", function()
  local doc = md({ "[![Logo](cid:logo@x)](https://x.com) and ![](data:image/png;base64,AA)", "after" })
  eq({ "L I Logo and I ", "", "after" }, doc.lines)
  eq(
    { { row = 1, alt = "Logo", source = "cid:logo@x" }, { row = 2, alt = "", source = "data:image/png;base64,AA" } },
    doc.images
  )
  eq("https://x.com", doc.links[1].url)
end)

describe("headings, bullets, quotes and rules get their icons", function()
  local doc = md({ "# Title", "## Sub", "- one", "  - two", "> quoted", "---" }, 10)
  eq({ "H1 Title", "H2 Sub", "* one", "  - two", "| quoted", string.rep("─", 10) }, doc.lines)
  eq({ { 1, "EmailH1Bg" }, { 2, "EmailH2Bg" } }, doc.line_highlights)
end)

describe("code blocks drop their fences and keep their text verbatim", function()
  local doc = md({ "```", "a **b** [c](d)", "```" })
  eq({ "a **b** [c](d)" }, doc.lines)
  eq({ { 1, "EmailCodeBlock" } }, doc.line_highlights)
end)

describe("tables become aligned box tables", function()
  local doc = md({ "| Name | Qty |", "| - | -: |", "| Apples | 3 |", "| [Pear](https://p.ex) | 12 |" })
  eq({
    "┌────────┬─────┐",
    "│ Name   │ Qty │",
    "├────────┼─────┤",
    "│ Apples │   3 │",
    "│ L Pear │  12 │",
    "└────────┴─────┘",
  }, doc.lines)
  eq({ { row = 5, start_col = #"│ ", end_col = #"│ L Pear", url = "https://p.ex" } }, doc.links)
end)

describe("wide tables shrink to the width and wrap inside their cells", function()
  local doc = md({ "| A | B |", "| - | - |", "| short | a long cell that needs wrapping |" }, 24)
  for _, line in ipairs(doc.lines) do
    eq(true, vim.fn.strdisplaywidth(line) <= 24)
  end
  eq("│ short │ a long cell  │", doc.lines[4])
  eq("│       │ that needs   │", doc.lines[5])
  eq("│       │ wrapping     │", doc.lines[6])
end)

describe("plain segments are left exactly as they are", function()
  local doc = markdown.render({ { lines = { "snake_case and 2 * 3 [x](y)" }, markdown = false } }, 40, opts)
  eq({ "snake_case and 2 * 3 [x](y)" }, doc.lines)
  eq({}, doc.links)
end)

describe("reply mode keeps urls readable inline", function()
  local doc = md({ "Go to [site](https://s.ex) or https://t.ex" }, 40, { inline_urls = true })
  eq({ "Go to site <https://s.ex> or https://t.ex" }, doc.lines)
end)

describe("an image on the last line gets a line after it, so the cursor can scroll past it", function()
  local images = require("email.images")
  local doc = md({ "text", "![pic](cid:a)" })
  images.pad_end(doc)
  eq({ "text", "I pic", "" }, doc.lines)
  local middle = md({ "![pic](cid:a)", "text" })
  images.pad_end(middle)
  eq({ "I pic", "text" }, middle.lines)
end)
