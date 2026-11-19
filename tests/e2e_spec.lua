---@diagnostic disable: duplicate-set-field
local root = vim.fn.tempname()
local mail = root .. "/mail"
for _, folder in ipairs({ "INBOX", "Sent", "Drafts", "Archive" }) do
  for _, sub in ipairs({ "cur", "new", "tmp" }) do
    vim.fn.mkdir(("%s/acct/%s/%s"):format(mail, folder, sub), "p")
  end
end
local config_path = root .. "/notmuch-config"
local function write(path, text)
  local fd = assert(io.open(path, "w"))
  fd:write(text)
  fd:close()
end
write(
  config_path,
  ("[database]\npath=%s\n[user]\nname=Test User\nprimary_email=me@example.com\n"):format(mail)
    .. "[new]\ntags=unread;inbox\n[maildir]\nsynchronize_flags=true\n"
)
for i = 1, 2 do
  write(
    ("%s/acct/INBOX/new/100%d.x,U=%d"):format(mail, i, i),
    ("From: Sender <s@example.org>\nTo: me@example.com\nSubject: Hello %d\nMessage-ID: <m%d@example.org>\n"):format(
      i,
      i
    )
      .. ("Date: Thu, 19 Nov 2026 10:0%d:00 +0000\nContent-Type: text/html; charset=utf-8\n\n<p>Hi %d</p>\n"):format(
        i,
        i
      )
  )
end
vim.env.NOTMUCH_CONFIG = config_path
assert(vim.system({ "notmuch", "new", "--quiet" }):wait().code == 0)

local errors = {}
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then
    errors[#errors + 1] = msg
  end
end
vim.o.columns, vim.o.lines = 160, 50

local sent_path = root .. "/sent.eml"
require("email").setup({
  accounts = {
    {
      name = "Acct",
      maildir = "acct",
      from = "Test User <me@example.com>",
      addresses = { "me@example.com" },
      inbox = "INBOX",
      sent = "Sent",
      drafts = "Drafts",
      archive = "Archive",
      folders = { { name = "INBOX", query = "tag:inbox" } },
    },
  },
  renderers = {
    ["text/html"] = function(html)
      return (html:gsub("<[^>]+>", ""))
    end,
  },
  send_cmd = { "sh", "-c", 'cat > "$0"', sent_path },
  refresh_interval = 0,
})

local state = require("email.state")
local function wait(what, predicate)
  if not vim.wait(5000, predicate, 10) then
    error(("timed out waiting for %s; errors: %s"):format(what, vim.inspect(errors)), 2)
  end
end
local function keys(lhs)
  vim.api.nvim_feedkeys(vim.keycode(lhs), "x", false)
end
local function files(folder)
  return vim.fn.glob(("%s/acct/%s/*/*"):format(mail, folder), false, true)
end

describe("e2e: list, read through a custom renderer and mark read", function()
  vim.cmd("Email")
  wait("list", function()
    return #state.messages == 2
  end)
  eq("Hello 2", state.messages[1].headers.Subject)
  vim.api.nvim_set_current_win(state.win.list)
  keys("<CR>")
  wait("reader", function()
    return state.current ~= nil and not state.messages[1].tags.unread
  end)
  local lines = vim.api.nvim_buf_get_lines(state.buf.reader, 0, -1, false)
  eq("Hi 2", lines[#lines])
end)

describe("e2e: reply, save a draft twice, send, and file the sent copy", function()
  keys("r")
  wait("composer", function()
    return vim.bo.filetype == "mail"
  end)
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "Svar med æøå" })
  vim.cmd("write")
  wait("draft", function()
    return #files("Drafts") == 1
  end)
  local first_draft = files("Drafts")[1]
  vim.cmd("write")
  wait("second draft", function()
    return #files("Drafts") == 1 and files("Drafts")[1] ~= first_draft
  end)
  keys("<C-s>")
  wait("send", function()
    return not vim.api.nvim_buf_is_valid(buf)
  end)
  eq(0, #files("Drafts"))
  eq(1, #files("Sent"))
  local sent = assert(io.open(sent_path)):read("*a")
  eq(true, sent:find("In-Reply-To: <m2@example.org>", 1, true) ~= nil)
  eq(true, sent:find("Svar med =C3=A6=C3=B8=C3=A5", 1, true) ~= nil)
  eq(true, sent:find("> Hi 2", 1, true) ~= nil)
  local tags = vim.trim(vim.system({ "notmuch", "search", "--output=tags", "id:m2@example.org" }):wait().stdout)
  eq(true, tags:find("replied", 1, true) ~= nil)
end)

describe("e2e: archive moves the file and drops the inbox tag; delete removes it", function()
  vim.api.nvim_set_current_win(state.win.list)
  vim.api.nvim_win_set_cursor(state.win.list, { 1, 0 })
  keys("a")
  wait("archive", function()
    return #state.messages == 1
  end)
  eq({ mail .. "/acct/Archive/cur/1002.x:2,RS" }, files("Archive"))
  local confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  keys("d")
  wait("delete", function()
    return #state.messages == 0
  end)
  vim.fn.confirm = confirm
  eq(0, #files("INBOX"))
  eq({}, errors)
end)
