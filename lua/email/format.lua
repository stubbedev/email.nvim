local text = require("email.text")

local M = {}

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
M.MAX_LISTED_ATTACHMENTS = 3

local SENDER_WIDTH = 22
local DATE_WIDTH = 10

function M.date(ts, now)
  local t, n = os.date("*t", ts), os.date("*t", now)
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
  return vim.trim((s or ""):gsub("%s+", " "))
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

function M.row(message, width, icons, now, marked)
  local iw = icon_width(icons)
  local segments = {}
  local status, status_hl = M.status_icon(message.tags, icons)
  local unread = message.tags.unread
  segments[#segments + 1] = { marked and M.fit(icons.marked, 1) or " ", marked and "EmailMarker" or nil }
  segments[#segments + 1] = { M.fit(status, iw) .. " ", status_hl }
  segments[#segments + 1] = { M.fit(message.tags.attachment and icons.attachment or "", iw) .. " ", "EmailAttachment" }
  local who = M.oneline(message.authors or message.sender)
  local badge = (message.total or 1) > 1 and (" " .. message.total) or ""
  local name = M.fit(who, SENDER_WIDTH - #badge)
  segments[#segments + 1] = { name, unread and "EmailSenderUnread" or "EmailSender" }
  segments[#segments + 1] = { badge .. "  ", "EmailCount" }
  local used = 0
  for _, segment in ipairs(segments) do
    used = used + text.width(segment[1])
  end
  local subject_width = math.max(10, width - used - DATE_WIDTH - 3)
  local subject = M.oneline(message.headers.Subject)
  segments[#segments + 1] = {
    M.fit(subject ~= "" and subject or "(no subject)", subject_width) .. "  ",
    unread and "EmailSubjectUnread" or "EmailSubject",
  }
  local date = M.date(message.timestamp, now)
  segments[#segments + 1] = { string.rep(" ", DATE_WIDTH - #date) .. date .. " ", "EmailDate" }

  local parts, highlights = {}, {}
  local col = 0
  for _, segment in ipairs(segments) do
    parts[#parts + 1] = segment[1]
    if segment[2] then
      highlights[#highlights + 1] = { col, col + #segment[1], segment[2] }
    end
    col = col + #segment[1]
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
