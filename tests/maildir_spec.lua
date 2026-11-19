local maildir = require("email.maildir")

local function touch(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write("x")
  fd:close()
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function fixture()
  local root = vim.fn.tempname()
  for _, folder in ipairs({ "INBOX", "Archive", "[Gmail]/All Mail" }) do
    for _, sub in ipairs({ "cur", "new", "tmp" }) do
      vim.fn.mkdir(root .. "/" .. folder .. "/" .. sub, "p")
    end
  end
  return root
end

describe("split finds the folder of a maildir file", function()
  eq(
    { "[Gmail]/All Mail", "1.2_3.host,U=9:2,S" },
    { maildir.split("/r/[Gmail]/All Mail/cur/1.2_3.host,U=9:2,S", "/r") }
  )
  eq(nil, maildir.split("/other/INBOX/cur/x", "/r"))
  eq(nil, maildir.split("/r/INBOX/tmp/x", "/r"))
end)

describe("target_name drops the mbsync UID and keeps flags", function()
  eq("1.2_3.host:2,FS", maildir.target_name("1.2_3.host,U=42:2,FS"))
  eq("1.2_3.host:2,", maildir.target_name("1.2_3.host,U=42"))
end)

describe("move renames into the target folder's cur", function()
  local root = fixture()
  local file = root .. "/INBOX/cur/1.2_3.host,U=7:2,S"
  touch(file)
  maildir.move({ file }, root, "Archive")
  eq(false, exists(file))
  eq(true, exists(root .. "/Archive/cur/1.2_3.host:2,S"))
end)

describe("move only unlinks the source when the target already has a copy", function()
  local root = fixture()
  local inbox = root .. "/INBOX/cur/a,U=1:2,S"
  local all = root .. "/[Gmail]/All Mail/cur/b,U=2:2,S"
  touch(inbox)
  touch(all)
  maildir.move({ inbox, all }, root, "[Gmail]/All Mail")
  eq(false, exists(inbox))
  eq(true, exists(all))
end)

describe("move ignores files of other accounts and fails when none are its own", function()
  local root = fixture()
  local other = vim.fn.tempname() .. "/INBOX/cur/z:2,"
  touch(other)
  local ok, err = pcall(maildir.move, { other }, root, "Archive")
  eq(false, ok)
  eq(true, tostring(err):find("no file of the message", 1, true) ~= nil)
  eq(true, exists(other))
end)

describe("unlink removes every file under the account root", function()
  local root = fixture()
  local a, b = root .. "/INBOX/cur/a:2,", root .. "/[Gmail]/All Mail/cur/b:2,"
  touch(a)
  touch(b)
  maildir.unlink({ a, b }, root)
  eq(false, exists(a))
  eq(false, exists(b))
end)

describe("folders lists nested maildirs sorted", function()
  eq({ "Archive", "INBOX", "[Gmail]/All Mail" }, maildir.folders(fixture()))
end)
