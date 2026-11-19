local reader = require("email.ui.reader")

vim.g.mapleader = " "
local config = vim.tbl_deep_extend("force", vim.deepcopy(require("email.config").defaults), {
  icons = { attachment = "@" },
})

local function message(count)
  local attachments = {}
  for i = 1, count do
    attachments[i] = { part = i, filename = ("file-%d.jpg"):format(i), content_type = "image/jpeg", size = 1024 }
  end
  return { headers = { From = "a@b.c", Subject = "s" }, timestamp = 0, attachments = attachments }
end

local function files_rows(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if line:find("file%-") or line:find("more,") then
      out[#out + 1] = vim.trim(line)
    end
  end
  return out
end

describe("reader lists up to three attachments in full", function()
  local lines = reader.lines(message(3), {}, 40, nil, config)
  eq({ "Files:    @ file-1.jpg (1 KiB)", "@ file-2.jpg (1 KiB)", "@ file-3.jpg (1 KiB)" }, files_rows(lines))
end)

describe("reader collapses long attachment lists into one summary line", function()
  local lines = reader.lines(message(250), {}, 40, nil, config)
  eq({
    "Files:    @ file-1.jpg (1 KiB)",
    "@ file-2.jpg (1 KiB)",
    "… 248 more, 250 KiB total · <Space>ma to browse",
  }, files_rows(lines))
end)
