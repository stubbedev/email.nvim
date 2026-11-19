local async = require("email.async")
local compose = require("email.compose")
local composer = require("email.ui.composer")
local format = require("email.format")
local help = require("email.ui.help")
local images = require("email.images")
local ical = require("email.ical")
local layout = require("email.ui.layout")
local list = require("email.ui.list")
local maildir = require("email.maildir")
local markdown = require("email.markdown")
local notmuch = require("email.notmuch")
local parse = require("email.parse")
local reader = require("email.ui.reader")
local render = require("email.render")
local sidebar = require("email.ui.sidebar")
local state = require("email.state")

local M = {}

M.descriptions = {
  help = "Show keys",
  compose = "Compose",
  reply = "Reply",
  reply_all = "Reply all",
  forward = "Forward",
  edit = "Edit draft",
  archive = "Archive",
  delete = "Delete",
  move = "Move to folder",
  toggle_unread = "Toggle unread",
  toggle_flagged = "Toggle flagged",
  attachments = "Open or save attachment",
  pipe = "Pipe message to command",
  search = "Search (notmuch query)",
  sync = "Sync mail",
  next_folder = "Next folder",
  prev_folder = "Previous folder",
  pick_folder = "Pick folder",
  open = "Open message",
  quit = "Quit",
  next_page = "Next page",
  prev_page = "Previous page",
  focus_sidebar = "Focus folders",
  close_reader = "Back to the list",
  open_link = "Open link under cursor",
  next_message = "Next message",
  prev_message = "Previous message",
  focus_list = "Focus list",
  select_folder = "Open folder",
  accept = "Accept invite",
  decline = "Decline invite",
  tentative = "Tentatively accept invite",
  mark = "Toggle mark",
  mark_all = "Mark all on page",
  unmark_all = "Clear marks",
  send = "Send",
  discard = "Discard",
}

local function query()
  return state.folder.search or state.folder.query
end

function M.refresh_counts()
  local queries, index = {}, {}
  for ai, account in ipairs(state.config.accounts) do
    for fi, folder in ipairs(account.folders) do
      queries[#queries + 1] = "(" .. folder.query .. ") and tag:unread"
      index[#queries] = { ai, fi }
    end
  end
  local counts = notmuch.counts(queries)
  local unread = {}
  for i, count in ipairs(counts) do
    local ai, fi = index[i][1], index[i][2]
    unread[ai] = unread[ai] or {}
    unread[ai][fi] = count
  end
  state.unread = unread
  sidebar.render()
end

function M.load_list(keep_id)
  state.load_generation = state.load_generation + 1
  local generation = state.load_generation
  local q = query()
  local total = notmuch.count(q)
  local pages = math.max(1, math.ceil(total / state.config.page_size))
  state.page = math.min(state.page, pages)
  local raws = notmuch.page(q, state.config.page_size, (state.page - 1) * state.config.page_size)
  if generation ~= state.load_generation or not layout.is_open() then
    return
  end
  state.total = total
  state.messages = vim.tbl_map(parse.summary, raws)
  list.render(keep_id)
end

function M.reload(keep_id)
  layout.with_busy("Loading", function()
    M.refresh_counts()
    M.load_list(keep_id)
  end)
end

local function target()
  if vim.api.nvim_get_current_win() == state.win.reader and state.current then
    return state.current
  end
  return list.selected() or error("no message selected", 0)
end

local function full(message)
  if message.blocks then
    return message
  end
  return parse.message(notmuch.show(message.id), state.config.alternatives)
end

local function in_visual()
  local mode = vim.fn.mode()
  return mode == "v" or mode == "V" or mode == "\22"
end

local function visual_rows()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return first, last
end

local function targets()
  if vim.api.nvim_get_current_win() == state.win.reader and state.current then
    return { state.current }
  end
  local out = {}
  if in_visual() then
    local first, last = visual_rows()
    for row = first, last do
      out[#out + 1] = state.messages[row]
    end
    return out
  end
  for _, message in ipairs(state.messages) do
    if state.marked[message.id] then
      out[#out + 1] = message
    end
  end
  if #out > 0 then
    return out
  end
  return { target() }
end

local function ids_of(messages)
  local ids = {}
  for i, message in ipairs(messages) do
    ids[i] = message.id
  end
  return ids
end

local function update_tags(ids, changes)
  notmuch.tag(ids, changes)
  local affected = {}
  for _, id in ipairs(ids) do
    affected[id] = true
  end
  local function apply(message)
    if message and affected[message.id] then
      for _, change in ipairs(changes) do
        message.tags[change:sub(2)] = change:sub(1, 1) == "+" or nil
      end
    end
  end
  for _, message in ipairs(state.messages) do
    apply(message)
  end
  apply(state.current)
  list.render()
  M.refresh_counts()
end

local function toggle_tag(tag)
  local messages = targets()
  local any = false
  for _, message in ipairs(messages) do
    any = any or message.tags[tag] == true
  end
  state.marked = {}
  update_tags(ids_of(messages), { (any and "-" or "+") .. tag })
end

local function invite_of(message)
  if #message.calendars == 0 then
    return nil
  end
  local calendar = ical.parse(compose.invite_text(message.id, message))
  return { summary = ical.summary(calendar), method = calendar.method }
end

local function show(summary)
  local pending
  layout.with_busy("Opening", function()
    local message = parse.message(notmuch.show(summary.id), state.config.alternatives)
    local config = state.config
    local segments = render.segments(message, config.renderers, config.markdown.types)
    local doc = markdown.render(segments, layout.reader_width(), config.markdown)
    local references = {}
    if config.images.enabled then
      images.append_attachments(message, doc, config.markdown.image)
      images.pad_end(doc)
      references = doc.images
    end
    state.current = message
    local buf, first_row = reader.show(message, doc, invite_of(message))
    if not vim.b[buf].email_bound then
      M.bind(buf, { "global", "reader" })
      vim.b[buf].email_bound = true
    end
    if message.tags.unread then
      update_tags({ message.id }, { "-unread" })
    end
    pending = { message = message, references = references, buf = buf, first_row = first_row }
  end)
  layout.focus("reader")
  if pending and #pending.references > 0 then
    images.show(pending.message, pending.references, pending.buf, pending.first_row)
  end
end

local function set_folder(folder)
  state.folder = folder
  state.page = 1
  state.marked = {}
  if state.reading then
    layout.close_reader()
  end
  M.reload()
end

local function neighbour(affected)
  local last
  for i, message in ipairs(state.messages) do
    if affected[message.id] then
      last = i
    end
  end
  if not last then
    return nil
  end
  for i = last + 1, #state.messages do
    if not affected[state.messages[i].id] then
      return state.messages[i].id
    end
  end
  for i = last - 1, 1, -1 do
    if not affected[state.messages[i].id] then
      return state.messages[i].id
    end
  end
  return nil
end

local function relocate(messages, folder_of, label)
  local ids = ids_of(messages)
  local affected = {}
  for _, id in ipairs(ids) do
    affected[id] = true
  end
  local keep = neighbour(affected)
  layout.with_busy(label, function()
    local files = notmuch.files_by_id(ids)
    local into_inbox, out_of_inbox = {}, {}
    local ok, err = pcall(function()
      for _, message in ipairs(messages) do
        local account = compose.account_of_message(message)
        local root = compose.root(account)
        local folder = folder_of(account)
        if folder then
          maildir.move(files[message.id], root, folder)
          table.insert(folder == account.inbox and into_inbox or out_of_inbox, message.id)
        else
          maildir.unlink(files[message.id], root)
        end
      end
    end)
    notmuch.reindex()
    if #into_inbox > 0 then
      notmuch.tag(into_inbox, { "+inbox" })
    end
    if #out_of_inbox > 0 then
      notmuch.tag(out_of_inbox, { "-inbox" })
    end
    if not ok then
      error(err, 0)
    end
  end)
  state.marked = {}
  if state.current and affected[state.current.id] then
    layout.close_reader()
  end
  M.reload(keep)
end

local function single_account(messages)
  local account
  for _, message in ipairs(messages) do
    local owner = compose.account_of_message(message)
    if account and owner ~= account then
      error("the selected messages belong to different accounts", 0)
    end
    account = owner
  end
  return account
end

local function count_label(messages)
  return #messages == 1 and ("%q"):format(format.oneline(messages[1].headers.Subject))
    or ("%d messages"):format(#messages)
end

local function pipe_to(message, cmd)
  local res = async.system(cmd, { stdin = notmuch.raw(message.id), text = true })
  local output = vim.trim((res.stdout or "") .. (res.stderr or ""))
  vim.notify(
    output ~= "" and output or ("`%s` exited %d"):format(table.concat(cmd, " "), res.code),
    res.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
  )
end

local function open_composer(draft)
  composer.open(draft, { send = compose.send, save = compose.save }, state.config.keymaps.composer, state.config.border)
end

local function prepare(fn, ...)
  local args = { ... }
  local draft
  layout.with_busy("Preparing", function()
    draft = fn(unpack(args))
  end)
  open_composer(draft)
end

local function unique_path(dir, filename)
  local path = dir .. "/" .. filename
  local stem, ext = filename:match("^(.*)(%.[^.]+)$")
  stem, ext = stem or filename, ext or ""
  local n = 1
  while vim.uv.fs_stat(path) do
    path = ("%s/%s (%d)%s"):format(dir, stem, n, ext)
    n = n + 1
  end
  return path
end

local function write_atomic(path, data)
  local tmp = path .. ".part"
  local fd, err = io.open(tmp, "wb")
  if not fd then
    error(("write %s: %s"):format(tmp, err), 0)
  end
  fd:write(data)
  fd:close()
  local ok, rename_err = vim.uv.fs_rename(tmp, path)
  if not ok then
    error(("rename %s to %s: %s"):format(tmp, path, rename_err), 0)
  end
end

local function step_folder(delta)
  local folders = sidebar.folders()
  local current = 0
  for i, folder in ipairs(folders) do
    if state.folder.account == folder.account and state.folder.index == folder.index then
      current = i
    end
  end
  set_folder(folders[(current - 1 + delta) % #folders + 1])
end

local function step_message(delta)
  local id = state.current and state.current.id or (list.selected() or {}).id
  for i, message in ipairs(state.messages) do
    if message.id == id then
      local next_message = state.messages[i + delta]
      if not next_message then
        return
      end
      list.select_id(next_message.id)
      show(next_message)
      return
    end
  end
end

M.handlers = {
  help = function()
    help.open(state.config.keymaps, M.descriptions, state.config.border, state.config.pipes)
  end,
  compose = function()
    local account = state.folder.account and state.config.accounts[state.folder.account] or state.config.accounts[1]
    open_composer(compose.new(account))
  end,
  reply = function()
    prepare(compose.reply, target().id, false)
  end,
  reply_all = function()
    prepare(compose.reply, target().id, true)
  end,
  forward = function()
    prepare(compose.forward, target().id)
  end,
  edit = function()
    prepare(compose.edit, target().id)
  end,
  archive = function()
    relocate(targets(), function(account)
      return account.archive or error(("account %s has no archive folder"):format(account.name), 0)
    end, "Archiving")
  end,
  delete = function()
    local messages = targets()
    if vim.fn.confirm(("Delete %s?"):format(count_label(messages)), "&Delete\n&Cancel", 2) == 1 then
      relocate(messages, function()
        return nil
      end, "Deleting")
    end
  end,
  move = function()
    local messages = targets()
    local account = single_account(messages)
    local folder =
      async.select(maildir.folders(compose.root(account)), { prompt = "Move " .. count_label(messages) .. " to" })
    if folder then
      relocate(messages, function()
        return folder
      end, "Moving")
    end
  end,
  toggle_unread = function()
    toggle_tag("unread")
  end,
  toggle_flagged = function()
    toggle_tag("flagged")
  end,
  accept = function()
    prepare(compose.calendar_reply, target().id, "ACCEPTED")
  end,
  decline = function()
    prepare(compose.calendar_reply, target().id, "DECLINED")
  end,
  tentative = function()
    prepare(compose.calendar_reply, target().id, "TENTATIVE")
  end,
  mark = function()
    if in_visual() then
      local first, last = visual_rows()
      for row = first, last do
        local message = state.messages[row]
        state.marked[message.id] = not state.marked[message.id] or nil
      end
      list.render()
      return
    end
    local message = list.selected()
    if not message then
      return
    end
    state.marked[message.id] = not state.marked[message.id] or nil
    local row = vim.api.nvim_win_get_cursor(state.win.list)[1]
    list.render()
    vim.api.nvim_win_set_cursor(state.win.list, { math.min(row + 1, math.max(1, #state.messages)), 0 })
  end,
  mark_all = function()
    for _, message in ipairs(state.messages) do
      state.marked[message.id] = true
    end
    list.render()
  end,
  unmark_all = function()
    state.marked = {}
    list.render()
  end,
  attachments = function()
    local message = full(target())
    if #message.attachments == 0 then
      vim.notify("email.nvim: no attachments")
      return
    end
    local attachment = async.select(message.attachments, {
      prompt = "Attachment",
      format_item = function(a)
        return ("%s %s (%s, %s)"):format(
          format.file_icon(a.filename, state.config),
          a.filename,
          a.content_type,
          format.size(a.size)
        )
      end,
    })
    if not attachment then
      return
    end
    local choice = async.select({ "Open", "Save" }, { prompt = attachment.filename })
    if not choice then
      return
    end
    local data = notmuch.part(message.id, attachment.part)
    local filename = attachment.filename:gsub("/", "_")
    if choice == "Save" then
      vim.fn.mkdir(state.config.downloads_dir, "p")
      local path = unique_path(state.config.downloads_dir, filename)
      write_atomic(path, data)
      vim.notify("email.nvim: saved " .. path)
      return
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. filename
    write_atomic(path, data)
    local _, err = vim.ui.open(path)
    if err then
      error(("open %s: %s"):format(path, err), 0)
    end
  end,
  pipe = function()
    local message = target()
    local cmd = async.input({ prompt = "Pipe message to: " })
    if not cmd or cmd == "" then
      return
    end
    pipe_to(message, { vim.o.shell, vim.o.shellcmdflag, cmd })
  end,
  search = function()
    local q = async.input({ prompt = "notmuch query: ", default = state.folder.search })
    if q and q ~= "" then
      set_folder({ search = q })
    end
  end,
  sync = function()
    local cmd = state.config.sync_cmd or error("sync_cmd is not configured", 0)
    layout.with_busy("Syncing", function()
      async.checked(cmd)
    end)
    M.reload()
  end,
  next_folder = function()
    step_folder(1)
  end,
  prev_folder = function()
    step_folder(-1)
  end,
  pick_folder = function()
    local folder = async.select(sidebar.folders(), {
      prompt = "Folder",
      format_item = function(f)
        return state.config.accounts[f.account].name .. " · " .. f.name
      end,
    })
    if folder then
      set_folder(folder)
    end
  end,
  open = function()
    local message = list.selected()
    if message then
      show(message)
    end
  end,
  quit = function()
    layout.close()
  end,
  next_page = function()
    if state.page * state.config.page_size < state.total then
      state.page = state.page + 1
      state.marked = {}
      M.reload()
    end
  end,
  prev_page = function()
    if state.page > 1 then
      state.page = state.page - 1
      state.marked = {}
      M.reload()
    end
  end,
  focus_sidebar = function()
    layout.focus("sidebar")
  end,
  close_reader = function()
    layout.close_reader()
  end,
  open_link = function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(state.win.reader))
    for _, link in ipairs(state.reader_links or {}) do
      if link.row == row and col >= link.start_col and col < link.end_col then
        local _, err = vim.ui.open(link.url)
        if err then
          error(("open %s: %s"):format(link.url, err), 0)
        end
        return
      end
    end
    vim.notify("email.nvim: no link under the cursor")
  end,
  next_message = function()
    step_message(1)
  end,
  prev_message = function()
    step_message(-1)
  end,
  focus_list = function()
    layout.focus("list")
  end,
  select_folder = function()
    local folder = sidebar.folder_at_cursor()
    if folder then
      set_folder(folder)
      layout.focus("list")
    end
  end,
}

M.contexts = {
  global = {},
  list = {},
  reader = {},
  sidebar = {},
  composer = {},
}
for context, maps in pairs(require("email.config").defaults.keymaps) do
  for action in pairs(maps) do
    M.contexts[context][action] = true
  end
end

local BATCH = { archive = true, delete = true, move = true, toggle_unread = true, toggle_flagged = true, mark = true }

function M.bind(buf, contexts)
  local visual = buf == state.buf.list
  for _, context in ipairs(contexts) do
    for action, lhs in pairs(state.config.keymaps[context]) do
      if lhs then
        local handler = M.handlers[action]
        local modes = (visual and BATCH[action]) and { "n", "x" } or "n"
        for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
          vim.keymap.set(modes, key, function()
            async.run(handler)
          end, { buffer = buf, nowait = true, desc = "email: " .. M.descriptions[action] })
        end
      end
    end
  end
  if vim.tbl_contains(contexts, "global") then
    for _, pipe in ipairs(state.config.pipes) do
      vim.keymap.set("n", pipe.key, function()
        async.run(function()
          pipe_to(target(), pipe.cmd)
        end)
      end, { buffer = buf, nowait = true, desc = "email: " .. pipe.desc })
    end
  end
end

function M.start_polling()
  local interval = state.config.refresh_interval
  if interval <= 0 or state.timer then
    return
  end
  state.timer = vim.uv.new_timer()
  state.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if not layout.is_open() then
        if state.timer then
          state.timer:stop()
          state.timer:close()
          state.timer = nil
        end
        return
      end
      if state.polling or state.busy > 0 then
        return
      end
      state.polling = true
      async.run(function()
        local ok, err = pcall(function()
          local lastmod = notmuch.lastmod()
          if lastmod ~= state.lastmod then
            state.lastmod = lastmod
            M.refresh_counts()
            M.load_list()
          end
        end)
        state.polling = false
        if not ok then
          error(err, 0)
        end
      end)
    end)
  )
end

function M.open_composer(draft)
  open_composer(draft)
end

return M
