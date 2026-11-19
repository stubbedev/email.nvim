local text = require("email.text")

local M = {}

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
M.MAX_LISTED_ATTACHMENTS = 3

local SENDER_WIDTH = 22
local DATE_WIDTH = 10

local DATE_CACHE_LIMIT = 4096
local calendar, calendar_size = {}, 0
local today, today_of = os.date("*t", 0), 0

local function calendar_of(ts)
  local t = calendar[ts]
  if t then
    return t
  end
  if calendar_size >= DATE_CACHE_LIMIT then
    calendar, calendar_size = {}, 0
  end
  t = os.date("*t", ts)
  calendar[ts], calendar_size = t, calendar_size + 1
  return t
end

function M.date(ts, now)
  if today_of ~= now then
    today, today_of = os.date("*t", now), now
  end
  local t, n = calendar_of(ts), today
  if t.year == n.year and t.yday == n.yday then
    return ("%02d:%02d"):format(t.hour, t.min)
  end
  if ts <= now and now - ts < 6 * 86400 then
    return ("%s %02d:%02d"):format(DAYS[t.wday], t.hour, t.min)
  end
  if t.year == n.year then
    return ("%s %02d"):format(MONTHS[t.month], t.day)
  end
  return ("%04d-%02d-%02d"):format(t.year, t.month, t.day)
end

function M.oneline(s)
  s = s or ""
  if s:find("[\t\n\r\v\f]") or s:find("  ", 1, true) then
    return vim.trim((s:gsub("%s+", " ")))
  end
  local first, last = 1, #s
  if s:byte(1) == 32 then
    first = 2
  end
  if last >= first and s:byte(last) == 32 then
    last = last - 1
  end
  return (first == 1 and last == #s) and s or s:sub(first, last)
end

M.fit = text.fit

function M.status_icon(tags, icons)
  if tags.flagged then
    return icons.flagged, "EmailFlagged"
  end
  if tags.unread then
    return icons.unread, "EmailUnread"
  end
  if tags.replied then
    return icons.replied, "EmailReplied"
  end
  return "", nil
end

local icon_widths = setmetatable({}, { __mode = "k" })

local function icon_width(icons)
  local width = icon_widths[icons]
  if width then
    return width
  end
  width = 0
  for _, icon in pairs(icons) do
    width = math.max(width, text.width(icon))
  end
  icon_widths[icons] = width
  return width
end

function M.row(message, width, icons, now, marked, highlights)
  highlights = highlights or {}
  local iw = icon_width(icons)
  local tags = message.tags
  local unread = tags.unread
  local status, status_hl = M.status_icon(tags, icons)
  local badge = (message.total or 1) > 1 and (" " .. message.total) or ""
  local subject = M.oneline(message.headers.Subject)
  local subject_width = math.max(10, width - (3 + 2 * iw + SENDER_WIDTH + 2) - DATE_WIDTH - 3)
  local date = M.date(message.timestamp, now)
  local parts = {
    marked and M.fit(icons.marked, 1) or " ",
    M.fit(status, iw) .. " ",
    M.fit(tags.attachment and icons.attachment or "", iw) .. " ",
    M.fit(M.oneline(message.authors or message.sender), SENDER_WIDTH - #badge),
    badge .. "  ",
    M.fit(subject ~= "" and subject or "(no subject)", subject_width) .. "  ",
    string.rep(" ", DATE_WIDTH - #date) .. date .. " ",
  }
  local groups = {
    marked and "EmailMarker" or false,
    status_hl or false,
    "EmailAttachment",
    unread and "EmailSenderUnread" or "EmailSender",
    "EmailCount",
    unread and "EmailSubjectUnread" or "EmailSubject",
    "EmailDate",
  }
  local col, n = 0, #highlights
  for k = 1, 7 do
    local stop = col + #parts[k]
    local group = groups[k]
    if group then
      highlights[n + 1], highlights[n + 2], highlights[n + 3] = col, stop, group
      n = n + 3
    end
    col = stop
  end
  return table.concat(parts), highlights
end

local FOLDER_ROLES = {
  inbox = "inbox",
  sent = "sent",
  ["sent items"] = "sent",
  ["sent mail"] = "sent",
  drafts = "drafts",
  draft = "drafts",
  archive = "archive",
  ["all mail"] = "archive",
  junk = "junk",
  ["junk mail"] = "junk",
  spam = "junk",
  trash = "trash",
  bin = "trash",
  deleted = "trash",
  ["deleted items"] = "trash",
}

function M.folder_icon(name, icons)
  return icons[FOLDER_ROLES[name:lower()] or "folder"]
end

function M.file_icon(filename, config)
  if not config.devicons then
    return config.icons.attachment, "EmailAttachment"
  end
  local icon, hl = require("nvim-web-devicons").get_icon(filename, filename:match("%.([^.]+)$"), { default = true })
  return icon, hl
end

function M.key(lhs)
  return vim.fn.keytrans(vim.keycode(lhs))
end

function M.keys(lhs)
  local out = {}
  for i, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
    out[i] = M.key(key)
  end
  return table.concat(out, " ")
end

function M.size(bytes)
  if not bytes then
    return "?"
  end
  if bytes < 1024 then
    return bytes .. " B"
  end
  if bytes < 1024 * 1024 then
    return ("%.0f KiB"):format(bytes / 1024)
  end
  return ("%.1f MiB"):format(bytes / 1024 / 1024)
end

return M
