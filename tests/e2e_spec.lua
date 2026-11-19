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
for i = 1, 3 do
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
write(
  mail .. "/acct/INBOX/new/1004.x,U=4",
  table.concat({
    "From: Organizer <org@example.org>",
    "To: me@example.com",
    "Subject: Invitation: Team sync",
    "Message-ID: <inv@example.org>",
    "Date: Thu, 19 Nov 2026 10:04:00 +0000",
    'Content-Type: multipart/alternative; boundary="b"',
    "",
    "--b",
    "Content-Type: text/html; charset=utf-8",
    "",
    "<p>Join us</p>",
    "--b",
    "Content-Type: text/calendar; charset=utf-8; method=REQUEST",
    "",
    "BEGIN:VCALENDAR",
    "METHOD:REQUEST",
    "BEGIN:VEVENT",
    "UID:abc-123",
    "SEQUENCE:0",
    "DTSTART:20261120T100000Z",
    "DTEND:20261120T110000Z",
    "SUMMARY:Team sync",
    "ORGANIZER;CN=Organizer:mailto:org@example.org",
    "ATTENDEE;CN=Test User;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com",
    "END:VEVENT",
    "END:VCALENDAR",
    "--b--",
    "",
  }, "\n")
)
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
local function read_sent()
  local fd = assert(io.open(sent_path))
  local sent = fd:read("*a")
  fd:close()
  return sent
end
local function subjects()
  local out = {}
  for i, message in ipairs(state.messages) do
    out[i] = message.headers.Subject
  end
  return out
end
local function focus_row(row)
  vim.api.nvim_set_current_win(state.win.list)
  vim.api.nvim_win_set_cursor(state.win.list, { row, 0 })
end

describe("e2e: the reader shows an invite row for calendar invitations", function()
  vim.cmd("Email")
  wait("list", function()
    return #state.messages == 4
  end)
  eq({ "Invitation: Team sync", "Hello 3", "Hello 2", "Hello 1" }, subjects())
  focus_row(1)
  keys("<CR>")
  wait("reader", function()
    return state.current ~= nil
  end)
  local text = table.concat(vim.api.nvim_buf_get_lines(state.buf.reader, 0, -1, false), "\n")
  eq(
    true,
    text:find("Invite:   " .. state.config.icons.invite .. " Team sync  (gy accept · gn decline · gm maybe)", 1, true)
      ~= nil
  )
end)

describe("e2e: accepting sends an iCalendar REPLY to the organizer", function()
  keys("gy")
  wait("composer", function()
    return vim.bo.filetype == "mail"
  end)
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd("stopinsert")
  eq({
    "From: Test User <me@example.com>",
    "To: Organizer <org@example.org>",
    "Cc: ",
    "Subject: Accepted: Team sync",
    "",
    "Test User has accepted the invitation.",
  }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  keys("<C-s>")
  wait("send", function()
    return not vim.api.nvim_buf_is_valid(buf)
  end)
  local sent = read_sent()
  eq(true, sent:find("Content-Type: text/calendar; charset=utf-8; method=REPLY", 1, true) ~= nil)
  local encoded = sent:match("method=REPLY\nContent%-Transfer%-Encoding: base64\n\n(.-)\n%-%-")
  local ics = vim.base64.decode((encoded:gsub("\n", "")))
  eq(true, ics:find("METHOD:REPLY", 1, true) ~= nil)
  eq(true, ics:find("ATTENDEE;CN=Test User;PARTSTAT=ACCEPTED:mailto:me@example.com", 1, true) ~= nil)
  keys("q")
end)

describe("e2e: recipient headers complete addresses from the notmuch index", function()
  local addresses = require("email.addresses")
  focus_row(2)
  keys("r")
  wait("composer", function()
    return vim.bo.filetype == "mail"
  end)
  wait("address cache including the organizer we just replied to", function()
    local cached = addresses.cached()
    return cached ~= nil and cached[1].addr == "org@example.org"
  end)
  vim.cmd("stopinsert")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "Cc: org" })
  vim.api.nvim_win_set_cursor(0, { 3, 7 })
  eq(4, addresses.omnifunc(1, ""))
  eq({
    { word = "Organizer <org@example.org>", menu = "[email]" },
    { word = "Sender <s@example.org>", menu = "[email]" },
  }, addresses.omnifunc(0, "org"))
  eq({ { word = "Organizer <org@example.org>", menu = "[email]" } }, addresses.omnifunc(0, "organ"))
  vim.api.nvim_win_set_cursor(0, { 4, 3 })
  eq(-3, addresses.omnifunc(1, ""))
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "Cc: " })
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "Svar med æøå" })
  vim.cmd("write")
  wait("draft", function()
    return #files("Drafts") == 1
  end)
  keys("<C-s>")
  wait("send", function()
    return not vim.api.nvim_buf_is_valid(buf)
  end)
  eq(0, #files("Drafts"))
  local sent = read_sent()
  eq(true, sent:find("In-Reply-To: <m3@example.org>", 1, true) ~= nil)
  eq(true, sent:find("Svar med =C3=A6=C3=B8=C3=A5", 1, true) ~= nil)
end)

describe("e2e: marked messages are archived together", function()
  focus_row(3)
  keys("v")
  keys("v")
  eq(2, vim.tbl_count(state.marked))
  keys("a")
  wait("archive", function()
    return #state.messages == 2
  end)
  eq({ "Invitation: Team sync", "Hello 3" }, subjects())
  eq(2, #files("Archive"))
  eq({}, state.marked)
end)

describe("e2e: a visual selection is deleted in one go", function()
  focus_row(1)
  local confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  keys("Vjd")
  wait("delete", function()
    return #state.messages == 0
  end)
  vim.fn.confirm = confirm
  eq(0, #files("INBOX"))
  eq({}, errors)
end)
