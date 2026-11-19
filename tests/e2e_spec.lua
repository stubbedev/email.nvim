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
for _, folder in ipairs({ "INBOX", "Sent", "Drafts", "Archive", "Trash" }) do
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

local errors, infos = {}, {}
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then
    errors[#errors + 1] = msg
  elseif level == nil or level == vim.log.levels.INFO then
    infos[#infos + 1] = msg
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
  for i, message in ipairs(state.threads) do
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
    return #state.threads == 4
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
    return #state.threads == 2
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
    return #state.threads == 0
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
    return #state.threads == 1
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
  local image = state.config.markdown.image
  eq(
    { row_of(image .. "Logo"), row_of(image .. "Logo") + 1, row_of(image .. "Logo") + 2, row_of(image .. "photo.jpg") },
    {
      placed[1].opts.pos[1] - 1,
      placed[2].opts.pos[1] - 1,
      placed[3].opts.pos[1] - 1,
      placed[4].opts.pos[1] - 1,
    }
  )
  eq(true, placed[1].src:match("%.png$") ~= nil)
  eq("\137PNG\r\n\26\n", assert(io.open(placed[2].src, "rb")):read("*a"))
  eq("http://127.0.0.1:9/gone.png", placed[3].src)
  eq(true, placed[4].src:match("%.jpg$") ~= nil)
  eq(nil, table.concat(lines, "\n"):find("base64", 1, true))
  eq(placed[4].opts.pos[1] + 1, #lines)
  eq("", lines[#lines])
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
    return #state.threads == 1 and state.threads[1].message_ids[1] == "many@example.org"
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

describe("e2e: the full layout uses normal windows in a tab of its own", function()
  require("email.ui.layout").close()
  state.config.layout = "full"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "not an empty tab" })
  vim.bo.modified = false
  local origin_tab, origin_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  vim.cmd("EmailSearch id:many@example.org")
  wait("the full layout to load the search", function()
    local win = state.win.list
    return win ~= nil
      and vim.api.nvim_win_is_valid(win)
      and state.busy == 0
      and vim.wo[win].winbar:find("id:many@example.org", 1, true) ~= nil
  end)
  local list_tab = vim.api.nvim_win_get_tabpage(state.win.list)
  eq(false, list_tab == origin_tab)
  eq("", vim.api.nvim_win_get_config(state.win.list).relative)
  eq("", vim.api.nvim_win_get_config(state.win.sidebar).relative)
  eq(list_tab, vim.api.nvim_win_get_tabpage(state.win.sidebar))
  eq(state.config.sidebar_width, vim.api.nvim_win_get_width(state.win.sidebar))
  eq(true, vim.wo[state.win.list].winbar:find("1 messages", 1, true) ~= nil)
  eq(false, vim.wo[state.win.list].number)

  focus_row(1)
  keys("<CR>")
  wait("reader", function()
    return state.current ~= nil and state.busy == 0
  end)
  local reader_tab = vim.api.nvim_win_get_tabpage(state.win.reader)
  eq(false, reader_tab == list_tab)
  eq("", vim.api.nvim_win_get_config(state.win.reader).relative)
  eq(true, vim.wo[state.win.reader].winbar:find("Many uploads", 1, true) ~= nil)
  eq(true, vim.wo[state.win.reader].winbar:find("q back", 1, true) ~= nil)

  keys("q")
  eq(false, vim.api.nvim_tabpage_is_valid(reader_tab))
  eq(state.win.list, vim.api.nvim_get_current_win())

  keys("q")
  eq(false, vim.api.nvim_tabpage_is_valid(list_tab))
  eq(true, vim.api.nvim_win_is_valid(origin_win))
  eq({}, errors)
  state.config.layout = "float"
end)

describe("e2e: the full layout takes over a tab that holds only an empty buffer", function()
  state.config.layout = "full"
  vim.cmd.tabnew()
  local empty_tab = vim.api.nvim_get_current_tabpage()
  local tabs = #vim.api.nvim_list_tabpages()
  vim.cmd("Email")
  wait("list", function()
    return state.win.list ~= nil and vim.api.nvim_win_is_valid(state.win.list) and state.busy == 0
  end)
  eq(empty_tab, vim.api.nvim_win_get_tabpage(state.win.list))
  eq(tabs, #vim.api.nvim_list_tabpages())
  vim.api.nvim_set_current_win(state.win.list)
  keys("q")
  eq(tabs - 1, #vim.api.nvim_list_tabpages())
  eq({}, errors)
  state.config.layout = "float"
end)

describe("e2e: scrolling near the end of the list loads the next batch", function()
  require("email.ui.layout").close()
  state.config.page_size = 2
  vim.cmd("EmailSearch *")
  wait("the first batch", function()
    return state.busy == 0 and #state.threads == 2 and state.total > 3
  end)
  local total = state.total
  focus_row(2)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf.list })
  wait("every message loaded as the cursor nears the end", function()
    if state.loading_more then
      return false
    end
    if #state.threads < total then
      focus_row(#state.threads)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf.list })
      return false
    end
    return true
  end)
  local seen = {}
  for _, message in ipairs(state.threads) do
    eq(nil, seen[message.id])
    seen[message.id] = true
  end
  require("email.async").run(require("email.actions").load_list)
  wait("a refresh keeps every loaded message", function()
    return state.busy == 0 and #state.threads == total
  end)
  state.config.page_size = 100
  eq({}, errors)
end)

describe("e2e: clicking a link in a message opens it and the mouse is put back", function()
  require("email.ui.layout").close()
  vim.o.mouse = ""
  vim.cmd("EmailSearch id:many@example.org")
  wait("message", function()
    return state.busy == 0 and #state.threads == 1
  end)
  focus_row(1)
  keys("<CR>")
  wait("reader", function()
    return state.current ~= nil and state.busy == 0
  end)
  eq("n", vim.o.mouse)
  state.reader_links = { { row = 2, start_col = 4, end_col = 9, url = "https://click.example" } }
  local opened = {}
  local open = vim.ui.open
  vim.ui.open = function(url)
    opened[#opened + 1] = url
    return nil, nil
  end
  eq(
    "email: Open the clicked link",
    vim.api.nvim_buf_call(state.buf.reader, function()
      return vim.fn.maparg("<LeftMouse>", "n", false, true).desc
    end)
  )
  local getmousepos = vim.fn.getmousepos
  local click = require("email.actions").handlers.click_link
  vim.fn.getmousepos = function()
    return { winid = state.win.reader, line = 2, column = 7 }
  end
  click()
  vim.fn.getmousepos = function()
    return { winid = state.win.reader, line = 2, column = 2 }
  end
  click()
  vim.fn.getmousepos = getmousepos
  vim.ui.open = open
  eq({ "https://click.example" }, opened)
  keys("q")
  eq("", vim.o.mouse)
  eq({}, errors)
end)

describe("e2e: delete moves to the trash, undo brings it back, and deleting from the trash is permanent", function()
  require("email.ui.layout").close()
  state.config.accounts[1].trash = "Trash"
  write(
    mail .. "/acct/INBOX/new/1007.x,U=7",
    "From: Sender <s@example.org>\nTo: me@example.com\nSubject: Trash me\nMessage-ID: <trash@example.org>\n"
      .. "Date: Thu, 19 Nov 2026 10:07:00 +0000\n\nbye\n"
  )
  assert(vim.system({ "notmuch", "new", "--quiet" }):wait().code == 0)
  vim.cmd("EmailSearch id:trash@example.org")
  wait("message", function()
    return state.busy == 0 and #state.threads == 1
  end)
  local asked = 0
  local confirm = vim.fn.confirm
  vim.fn.confirm = function()
    asked = asked + 1
    return 1
  end
  focus_row(1)
  keys("d")
  wait("the move to the trash", function()
    return #files("Trash") == 1 and state.busy == 0
  end)
  eq(0, asked)
  eq(0, #vim.fn.glob(mail .. "/acct/INBOX/*/1007*", false, true))
  local tags = vim.system({ "notmuch", "search", "--output=tags", "id:trash@example.org" }):wait().stdout or ""
  eq(nil, tags:find("inbox", 1, true))

  keys("U")
  wait("the undo", function()
    return #files("Trash") == 0 and state.busy == 0
  end)
  eq(1, #vim.fn.glob(mail .. "/acct/INBOX/cur/1007*", false, true))
  tags = vim.system({ "notmuch", "search", "--output=tags", "id:trash@example.org" }):wait().stdout or ""
  eq(true, tags:find("inbox", 1, true) ~= nil)

  keys("d")
  wait("the second move to the trash", function()
    return #files("Trash") == 1 and state.busy == 0
  end)
  vim.cmd("EmailSearch id:trash@example.org")
  wait("message in the trash", function()
    return state.busy == 0 and #state.threads == 1
  end)
  focus_row(1)
  keys("d")
  wait("the permanent delete", function()
    return #files("Trash") == 0 and state.busy == 0
  end)
  eq(1, asked)
  eq("", vim.trim(vim.system({ "notmuch", "search", "id:trash@example.org" }):wait().stdout))
  vim.fn.confirm = confirm
  state.config.accounts[1].trash = nil
  eq({}, errors)
end)

describe(
  "e2e: a conversation opens whole, older read messages folded, actions on the message under the cursor",
  function()
    require("email.ui.layout").close()
    local function message(n, subject, extra, flags)
      write(
        ("%s/acct/INBOX/cur/20%02d.x,U=%d:2,%s"):format(mail, n, 100 + n, flags),
        ("From: Person %d <p%d@example.org>\nTo: me@example.com\nSubject: %s\nMessage-ID: <c%d@example.org>\n"):format(
          n,
          n,
          subject,
          n
        )
          .. extra
          .. ("Date: Thu, 19 Nov 2026 11:0%d:00 +0000\n\nbody %d\nsecond line\nthird line\n"):format(n, n)
      )
    end
    message(1, "Plans", "", "S")
    message(2, "Re: Plans", "In-Reply-To: <c1@example.org>\nReferences: <c1@example.org>\n", "S")
    message(3, "Re: Plans", "In-Reply-To: <c2@example.org>\nReferences: <c1@example.org> <c2@example.org>\n", "")
    assert(vim.system({ "notmuch", "new", "--quiet" }):wait().code == 0)
    vim.cmd("EmailSearch id:c1@example.org or id:c2@example.org or id:c3@example.org")
    wait("one conversation", function()
      return state.busy == 0 and #state.threads == 1
    end)
    eq(3, state.threads[1].total)
    local row = vim.api.nvim_buf_get_lines(state.buf.list, 0, 1, false)[1]
    eq(true, row:find("Person 1, Person 2, Person 3", 1, true) ~= nil or row:find(" 3  ", 1, true) ~= nil)
    focus_row(1)
    keys("<CR>")
    wait("the conversation", function()
      return state.sections ~= nil and #state.sections == 3 and state.busy == 0
    end)
    eq("c3@example.org", state.current.id)
    eq(state.sections[3].first, vim.api.nvim_win_get_cursor(state.win.reader)[1])
    local function closed_at(index)
      return vim.api.nvim_win_call(state.win.reader, function()
        return vim.fn.foldclosed(state.sections[index].body + 1)
      end)
    end
    eq(true, closed_at(1) > 0)
    eq(true, closed_at(2) > 0)
    eq(-1, closed_at(3))
    keys("[m")
    eq(state.sections[2].first, vim.api.nvim_win_get_cursor(state.win.reader)[1])
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf.reader })
    eq("c2@example.org", state.current.id)
    keys("r")
    wait("composer", function()
      return vim.bo.filetype == "mail"
    end)
    local header = vim.api.nvim_buf_get_lines(0, 0, 4, false)
    eq("To: Person 2 <p2@example.org>", header[2])
    vim.cmd("stopinsert")
    vim.bo.modified = false
    vim.api.nvim_win_close(0, true)
    local tags = vim.system({ "notmuch", "search", "--output=tags", "id:c3@example.org" }):wait().stdout or ""
    eq(nil, tags:find("unread", 1, true))
    keys("q")
    focus_row(1)
    keys("a")
    wait("the conversation archived", function()
      return state.busy == 0 and #vim.fn.glob(mail .. "/acct/INBOX/cur/20*", false, true) == 0
    end)
    eq(3, #vim.fn.glob(mail .. "/acct/Archive/cur/20*", false, true))
    eq({}, errors)
  end
)

describe("e2e: smart folders are saved searches above the accounts, with unread counts", function()
  require("email.ui.layout").close()
  state.config.searches = { { name = "Flagged", query = "tag:flagged" } }
  write(
    mail .. "/acct/INBOX/new/1010.x,U=10:2,F",
    "From: Star <s@example.org>\nTo: me@example.com\nSubject: Starred one\nMessage-ID: <star@example.org>\n"
      .. "Date: Thu, 19 Nov 2026 12:00:00 +0000\n\nkeep\n"
  )
  assert(vim.system({ "notmuch", "new", "--quiet" }):wait().code == 0)
  assert(vim.system({ "notmuch", "tag", "+flagged", "--", "id:star@example.org" }):wait().code == 0)
  state.folder = nil
  vim.cmd("Email")
  wait("the sidebar", function()
    return state.busy == 0 and state.unread.smart ~= nil and state.unread.smart[1] ~= nil
  end)
  local lines = vim.api.nvim_buf_get_lines(state.buf.sidebar, 0, -1, false)
  eq(true, lines[1]:find("Smart", 1, true) ~= nil)
  eq(true, lines[2]:find("Flagged", 1, true) ~= nil)
  eq(true, lines[2]:find("1 $") ~= nil)
  eq(nil, state.folder.smart)
  eq(1, state.folder.account)
  vim.api.nvim_set_current_win(state.win.sidebar)
  vim.api.nvim_win_set_cursor(state.win.sidebar, { 2, 0 })
  keys("<CR>")
  wait("the smart folder's list", function()
    return state.busy == 0 and state.folder.smart and #state.threads == 1
  end)
  eq("Starred one", state.threads[1].headers.Subject)
  vim.api.nvim_set_current_win(state.win.list)
  keys("<S-l>")
  wait("the next folder", function()
    return state.busy == 0 and state.folder.smart == nil
  end)
  eq(1, state.folder.account)
  state.config.searches = {}
  eq({}, errors)
end)

describe("e2e: signatures, the attach picker, an HTML alternative and undo send", function()
  require("email.ui.layout").close()
  local account = state.config.accounts[1]
  account.signature = "Test User\nexample.com"
  state.config.html_cmd = { "sh", "-c", "printf '<p>'; cat; printf '</p>'" }
  state.config.send_delay = 1
  local attachment = root .. "/notes.txt"
  write(attachment, "notes")
  state.config.attach_picker = function(add)
    add({ attachment })
  end
  vim.cmd("Email")
  wait("list", function()
    return state.busy == 0 and state.win.list ~= nil
  end)
  vim.api.nvim_set_current_win(state.win.list)
  keys("c")
  wait("composer", function()
    return vim.bo.filetype == "mail"
  end)
  vim.cmd("stopinsert")
  local buf = vim.api.nvim_get_current_buf()
  eq({ "", "", "-- ", "Test User", "example.com" }, vim.api.nvim_buf_get_lines(buf, 5, -1, false))
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "To: friend@example.org" })
  vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "Subject: With extras" })
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "**hello**" })
  keys("<leader>ma")
  eq("Attach: " .. attachment, vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])

  os.remove(sent_path)
  keys("<leader>ms")
  wait("the composer to hide", function()
    return state.pending_send ~= nil
  end)
  eq(false, vim.api.nvim_get_current_buf() == buf)
  require("email.async").run(require("email.actions").handlers.undo)
  wait("the composer back", function()
    return state.pending_send == nil and vim.api.nvim_get_current_buf() == buf
  end)
  vim.wait(1500)
  eq(nil, io.open(sent_path))

  keys("<leader>ms")
  wait("the delayed send", function()
    return not vim.api.nvim_buf_is_valid(buf) and io.open(sent_path) ~= nil and state.busy == 0
  end)
  local sent = read_sent()
  eq(true, sent:find("Content-Type: multipart/mixed", 1, true) ~= nil)
  eq(true, sent:find("Content-Type: multipart/alternative", 1, true) ~= nil)
  local html = sent:match("Content%-Type: text/html; charset=utf%-8\nContent%-Transfer%-Encoding: base64\n\n(.-)\n%-%-")
  eq(true, vim.base64.decode((html:gsub("\n", ""))):find("<p>**hello**", 1, true) ~= nil)
  eq(true, sent:find('filename="notes.txt"', 1, true) ~= nil)
  eq(true, sent:find("Test User", 1, true) ~= nil)

  account.signature = nil
  state.config.html_cmd = nil
  state.config.send_delay = 0
  state.config.attach_picker = nil
  eq({}, errors)
end)

describe("e2e: a reply puts the signature above the quoted message", function()
  state.config.accounts[1].signature = "Test User"
  local draft
  require("email.async").run(function()
    draft = require("email.compose").reply("c2@example.org", false)
  end)
  wait("the reply draft", function()
    return draft ~= nil
  end)
  eq({ "", "", "-- ", "Test User", "" }, vim.list_slice(draft.body, 1, 5))
  eq(true, draft.body[6]:find("wrote:$") ~= nil)
  state.config.accounts[1].signature = nil
  eq({}, errors)
end)
