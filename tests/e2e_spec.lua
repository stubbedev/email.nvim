---@diagnostic disable: duplicate-set-field
vim.g.mapleader = " "
local placed = {}
package.preload["snacks"] = function()
  return {
    image = {
      placement = {
        new = function(buf, src, opts)
          local placement = { buf = buf, src = src, opts = opts, closed = false }
          function placement.close(self)
            self.closed = true
          end
          placed[#placed + 1] = placement
          return placement
        end,
      },
    },
  }
end
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
      return (html:gsub('<img src="([^"]+)" alt="([^"]*)">', "![%2](%1)"):gsub("<[^>]+>", ""))
    end,
  },
  images = { enabled = true, remote = true },
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
  eq(true, vim.api.nvim_win_get_config(state.win.list).hide)
  eq(true, vim.api.nvim_win_get_config(state.win.sidebar).hide)
  eq(state.win.reader, vim.api.nvim_get_current_win())
  eq(
    vim.api.nvim_win_get_width(state.win.sidebar) + vim.api.nvim_win_get_width(state.win.list) + 2,
    vim.api.nvim_win_get_width(state.win.reader)
  )
  eq(" 1 of 4 · q back · [[ prev · ]] next ", vim.api.nvim_win_get_config(state.win.reader).footer[1][1])
  local text = table.concat(vim.api.nvim_buf_get_lines(state.buf.reader, 0, -1, false), "\n")
  eq(
    true,
    text:find(
      "Invite:   "
        .. state.config.icons.invite
        .. " Team sync  (<Space>my accept · <Space>mn decline · <Space>mt maybe)",
      1,
      true
    ) ~= nil
  )
end)

describe("e2e: accepting sends an iCalendar REPLY to the organizer", function()
  keys("<leader>my")
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
  keys("<leader>ms")
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

describe("e2e: q leaves the message and brings the folders and list back", function()
  eq(false, vim.api.nvim_win_get_config(state.win.list).hide)
  eq(false, vim.api.nvim_win_get_config(state.win.sidebar).hide)
  eq(state.win.list, vim.api.nvim_get_current_win())
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
  keys("<leader>ms")
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
  keys("<Tab>")
  keys("<Tab>")
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

describe("e2e: inline cid and data images and attached photos are placed in the reader", function()
  local png = vim.base64.encode("\137PNG\r\n\26\n")
  write(
    mail .. "/acct/INBOX/new/1005.x,U=5",
    table.concat({
      "From: Sender <s@example.org>",
      "To: me@example.com",
      "Subject: Pictures",
      "Message-ID: <pic@example.org>",
      "Date: Thu, 19 Nov 2026 10:05:00 +0000",
      'Content-Type: multipart/mixed; boundary="m"',
      "",
      "--m",
      'Content-Type: multipart/related; boundary="r"',
      "",
      "--r",
      "Content-Type: text/html; charset=utf-8",
      "",
      '<p>Logo</p><img src="cid:logo@x" alt="Logo"><p>Inline</p><img src="data:image/png;base64,'
        .. png
        .. '" alt=""><img src="http://127.0.0.1:9/gone.png" alt="gone">',
      "--r",
      "Content-Type: image/png",
      "Content-ID: <logo@x>",
      "Content-Disposition: inline",
      "Content-Transfer-Encoding: base64",
      "",
      png,
      "--r--",
      "--m",
      "Content-Type: image/jpeg",
      'Content-Disposition: attachment; filename="photo.jpg"',
      "Content-Transfer-Encoding: base64",
      "",
      vim.base64.encode("JPEGDATA"),
      "--m--",
      "",
    }, "\n")
  )
  assert(vim.system({ "notmuch", "new", "--quiet" }):wait().code == 0)
  vim.cmd("Email")
  wait("picture message", function()
    return #state.messages == 1
  end)
  focus_row(1)
  keys("<CR>")
  wait("four images", function()
    return #placed == 4
  end)
  local lines = vim.api.nvim_buf_get_lines(state.buf.reader, 0, -1, false)
  local function row_of(anchor)
    for i, line in ipairs(lines) do
      if line:find(anchor, 1, true) then
        return i - 1
      end
    end
  end
  for _, placement in ipairs(placed) do
    eq(state.buf.reader, placement.buf)
    eq(true, placement.opts.inline)
  end
  eq({ row_of("#image-1"), row_of("#image-1") + 1, row_of("#image-1") + 2, row_of("#image-4") }, {
    placed[1].opts.pos[1] - 1,
    placed[2].opts.pos[1] - 1,
    placed[3].opts.pos[1] - 1,
    placed[4].opts.pos[1] - 1,
  })
  eq(true, placed[1].src:match("%.png$") ~= nil)
  eq("\137PNG\r\n\26\n", assert(io.open(placed[2].src, "rb")):read("*a"))
  eq("http://127.0.0.1:9/gone.png", placed[3].src)
  eq(true, placed[4].src:match("%.jpg$") ~= nil)
  eq(nil, table.concat(lines, "\n"):find("base64", 1, true))
  keys("q")
  for _, placement in ipairs(placed) do
    eq(true, placement.closed)
  end
  eq({}, errors)
end)

describe("e2e: attached photos are not drawn once the attachment list collapses", function()
  local parts = {
    "From: Uploader <up@example.org>",
    "To: me@example.com",
    "Subject: Many uploads",
    "Message-ID: <many@example.org>",
    "Date: Thu, 19 Nov 2026 10:06:00 +0000",
    'Content-Type: multipart/mixed; boundary="m"',
    "",
    "--m",
    "Content-Type: text/plain; charset=utf-8",
    "",
    "Uploaded.",
  }
  for i = 1, 5 do
    vim.list_extend(parts, {
      "--m",
      "Content-Type: image/jpeg",
      ('Content-Disposition: attachment; filename="up-%d.jpg"'):format(i),
      "Content-Transfer-Encoding: base64",
      "",
      vim.base64.encode("JPEGDATA"),
    })
  end
  vim.list_extend(parts, { "--m--", "" })
  write(mail .. "/acct/INBOX/new/1006.x,U=6", table.concat(parts, "\n"))
  assert(vim.system({ "notmuch", "new", "--quiet" }):wait().code == 0)
  vim.cmd("EmailSearch id:many@example.org")
  wait("upload message", function()
    return #state.messages == 1 and state.messages[1].id == "many@example.org"
  end)
  local before = #placed
  focus_row(1)
  keys("<CR>")
  wait("reader", function()
    return state.current ~= nil and state.current.id == "many@example.org" and state.busy == 0
  end)
  vim.wait(200)
  eq(before, #placed)
  eq(5, #state.current.attachments)
  keys("q")
end)
