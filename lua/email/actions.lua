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
  open = "Open conversation",
  quit = "Quit",
  focus_sidebar = "Focus folders",
  close_reader = "Back to the list",
  open_link = "Open link under cursor",
  click_link = "Open the clicked link",
  next_message = "Next conversation",
  prev_message = "Previous conversation",
  next_in_thread = "Next message in the conversation",
  prev_in_thread = "Previous message in the conversation",
  focus_list = "Focus list",
  select_folder = "Open folder",
  accept = "Accept invite",
  decline = "Decline invite",
  tentative = "Tentatively accept invite",
  mark = "Toggle mark",
  mark_all = "Mark all on page",
  unmark_all = "Clear marks",
  undo = "Undo the last move, delete or send",
  send = "Send",
  discard = "Discard",
}

local function query()
  return state.folder.search or state.folder.query
end

function M.refresh_counts()
  local folders = sidebar.folders()
  local queries = {}
  for i, folder in ipairs(folders) do
    queries[i] = "(" .. folder.query .. ") and tag:unread"
  end
  local counts = notmuch.counts(queries)
  local unread = { smart = {} }
  for i, folder in ipairs(folders) do
    local group = folder.smart and "smart" or folder.account
    unread[group] = unread[group] or {}
    unread[group][folder.index] = counts[i]
  end
  state.unread = unread
  sidebar.render()
end

function M.load_list(keep_id)
  state.load_generation = state.load_generation + 1
  local generation = state.load_generation
  local q = query()
  local total = notmuch.count_threads(q)
  local raws = notmuch.threads(q, math.max(state.config.page_size, #state.threads), 0)
  if generation ~= state.load_generation or not layout.is_open() then
    return
  end
  state.total = total
  state.threads = vim.tbl_map(parse.thread, raws)
  list.render(keep_id)
end

local SCROLL_AHEAD = 20

function M.load_more()
  if state.loading_more or #state.threads >= state.total then
    return
  end
  state.loading_more = true
  local generation = state.load_generation
  local ok, err = pcall(function()
    local raws = notmuch.threads(query(), state.config.page_size, #state.threads)
    if generation ~= state.load_generation or not layout.is_open() then
      return
    end
    local known = {}
    for _, thread in ipairs(state.threads) do
      known[thread.id] = true
    end
    for _, raw in ipairs(raws) do
      if not known[raw.thread] then
        state.threads[#state.threads + 1] = parse.thread(raw)
      end
    end
    list.render()
  end)
  state.loading_more = false
  if not ok then
    error(err, 0)
  end
end

function M.near_end()
  local win = state.win.list
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  return vim.api.nvim_win_get_cursor(win)[1] > #state.threads - SCROLL_AHEAD
end

function M.reload(keep_id)
  layout.with_busy("Loading", function()
    M.refresh_counts()
    M.load_list(keep_id)
  end)
end

local function reading()
  return vim.api.nvim_get_current_win() == state.win.reader and state.current ~= nil
end

local function target()
  if reading() then
    return state.current
  end
  local thread = list.selected() or error("no conversation selected", 0)
  return parse.message(notmuch.show(notmuch.newest_message(thread.id, query())), state.config.alternatives)
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

local function selected_threads()
  local out = {}
  if in_visual() then
    local first, last = visual_rows()
    for row = first, last do
      out[#out + 1] = state.threads[row]
    end
    return out
  end
  for _, thread in ipairs(state.threads) do
    if state.marked[thread.id] then
      out[#out + 1] = thread
    end
  end
  if #out > 0 then
    return out
  end
  return { list.selected() or error("no conversation selected", 0) }
end

local function ids_of(messages)
  local ids = {}
  for i, message in ipairs(messages) do
    ids[i] = message.id
  end
  return ids
end

local function selection()
  if reading() then
    return { state.current }, {}, ("%q"):format(format.oneline(state.current.headers.Subject))
  end
  local threads = selected_threads()
  local ids = {}
  for _, thread in ipairs(threads) do
    vim.list_extend(ids, thread.message_ids)
  end
  local files = notmuch.files_by_id(ids)
  local messages = {}
  for i, id in ipairs(ids) do
    messages[i] = { id = id, files = files[id] }
  end
  local label = #threads == 1 and ("%q"):format(format.oneline(threads[1].headers.Subject))
    or ("%d conversations"):format(#threads)
  return messages, threads, label
end

local function toggle_tag(tag)
  local messages, threads = selection()
  local any = reading() and state.current.tags[tag] == true
  for _, thread in ipairs(threads) do
    any = any or thread.tags[tag] == true
  end
  local change = (any and "-" or "+") .. tag
  notmuch.tag(ids_of(messages), { change })
  if reading() then
    state.current.tags[tag] = not any or nil
  end
  state.marked = {}
  M.load_list()
  M.refresh_counts()
end

local function invite_of(message)
  if #message.calendars == 0 then
    return nil
  end
  local calendar = ical.parse(compose.invite_text(message.id, message))
  return { summary = ical.summary(calendar), method = calendar.method }
end

local function render_message(message)
  local config = state.config
  local segments = render.segments(message, config.renderers, config.markdown.types)
  local doc = markdown.render(segments, layout.reader_width(), config.markdown)
  if config.images.enabled then
    images.append_attachments(message, doc, config.markdown.image)
    images.pad_end(doc)
  end
  return doc
end

local function show(thread)
  local pending = {}
  layout.with_busy("Opening", function()
    local entries, unread = {}, {}
    for _, raw in ipairs(notmuch.thread(thread.id)) do
      local message = parse.message(raw, state.config.alternatives)
      entries[#entries + 1] = { message = message, doc = render_message(message), invite = invite_of(message) }
      if message.tags.unread then
        unread[#unread + 1] = message.id
      end
    end
    state.thread = thread.id
    local buf, focus = reader.show(thread.id, entries)
    state.current = focus
    if not vim.b[buf].email_bound then
      M.bind(buf, { "global", "reader" })
      vim.b[buf].email_bound = true
    end
    if #unread > 0 then
      notmuch.tag(unread, { "-unread" })
      for _, entry in ipairs(entries) do
        entry.message.tags.unread = nil
      end
      thread.tags.unread = nil
      list.render()
      M.refresh_counts()
    end
    if state.config.images.enabled then
      for index, entry in ipairs(entries) do
        if #entry.doc.images > 0 then
          pending[#pending + 1] =
            { message = entry.message, references = entry.doc.images, first_row = state.sections[index].body }
        end
      end
    end
    pending.buf = buf
  end)
  layout.focus("reader")
  if #pending > 0 then
    images.show(pending, pending.buf)
  end
end

local function set_folder(folder)
  state.folder = folder
  state.threads = {}
  state.marked = {}
  if state.reading then
    layout.close_reader()
  end
  M.reload()
end

local function neighbour(affected)
  local last
  for i, thread in ipairs(state.threads) do
    if affected[thread.id] then
      last = i
    end
  end
  if not last then
    return nil
  end
  for i = last + 1, #state.threads do
    if not affected[state.threads[i].id] then
      return state.threads[i].id
    end
  end
  for i = last - 1, 1, -1 do
    if not affected[state.threads[i].id] then
      return state.threads[i].id
    end
  end
  return nil
end

local function sync_soon()
  local cmd = state.config.sync_cmd
  if cmd then
    vim.system(cmd, {}, function() end)
  end
end

local function retag_inbox(into, out_of)
  if #into > 0 then
    notmuch.tag(into, { "+inbox" })
  end
  if #out_of > 0 then
    notmuch.tag(out_of, { "-inbox" })
  end
end

local function relocate(messages, threads, destination, label)
  local ids = ids_of(messages)
  local affected = {}
  for _, thread in ipairs(threads) do
    affected[thread.id] = true
  end
  local keep = neighbour(affected)
  local stash = vim.fn.tempname()
  vim.fn.mkdir(stash, "p")
  local undo = { label = label, journal = {}, into_inbox = {}, out_of_inbox = {} }
  layout.with_busy(label, function()
    local files = notmuch.files_by_id(ids)
    local into_inbox, out_of_inbox = {}, {}
    local ok, err = pcall(function()
      for _, message in ipairs(messages) do
        local account = compose.account_of_message(message)
        local root = compose.root(account)
        local own = files[message.id]
        local was_in_inbox = vim.iter(own):any(function(file)
          return maildir.split(file, root) == account.inbox
        end)
        local folder = destination(account, own, root)
        if folder then
          maildir.move(own, root, folder, stash, undo.journal)
          table.insert(folder == account.inbox and into_inbox or out_of_inbox, message.id)
        else
          maildir.unlink(own, root, stash, undo.journal)
        end
        table.insert(was_in_inbox and undo.into_inbox or undo.out_of_inbox, message.id)
      end
    end)
    notmuch.reindex()
    retag_inbox(into_inbox, out_of_inbox)
    if not ok then
      error(err, 0)
    end
  end)
  state.undo = undo
  state.marked = {}
  if state.reading then
    layout.close_reader()
  end
  M.reload(keep)
  sync_soon()
end

local function in_trash(account, own, root)
  return account.trash ~= nil and maildir.in_folder(own, root, account.trash)
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

local function link_at(row, col)
  for _, link in ipairs(state.reader_links or {}) do
    if link.row == row and col >= link.start_col and col < link.end_col then
      return link
    end
  end
  return nil
end

local function open_url(url)
  local _, err = vim.ui.open(url)
  if err then
    error(("open %s: %s"):format(url, err), 0)
  end
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
    if sidebar.same(state.folder, folder) then
      current = i
    end
  end
  set_folder(folders[(current - 1 + delta) % #folders + 1])
end

local function step_thread(delta)
  local id = state.thread or (list.selected() or {}).id
  for i, thread in ipairs(state.threads) do
    if thread.id == id then
      if delta > 0 and i + delta > #state.threads then
        M.load_more()
      end
      local next_thread = state.threads[i + delta]
      if not next_thread then
        return
      end
      list.select_id(next_thread.id)
      show(next_thread)
      return
    end
  end
end

local function step_in_thread(delta)
  local row = vim.api.nvim_win_get_cursor(state.win.reader)[1]
  local _, index = reader.section_at(row)
  local section = state.sections[(index or 1) + delta]
  if section then
    vim.api.nvim_win_set_cursor(state.win.reader, { section.first, 0 })
    vim.api.nvim_win_call(state.win.reader, function()
      vim.cmd("normal! zt")
    end)
  end
end

M.handlers = {
  help = function()
    help.open(state.config.keymaps, M.descriptions, state.config.border)
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
    local messages, threads = selection()
    relocate(messages, threads, function(account)
      return account.archive or error(("account %s has no archive folder"):format(account.name), 0)
    end, "Archiving")
  end,
  delete = function()
    local messages, threads, label = selection()
    local files = notmuch.files_by_id(ids_of(messages))
    local permanent = vim.iter(messages):any(function(message)
      local account = compose.account_of_message(message)
      return account.trash == nil or in_trash(account, files[message.id], compose.root(account))
    end)
    if permanent then
      local question = ("Permanently delete %s?"):format(label)
      if vim.fn.confirm(question, "&Delete\n&Cancel", 2) ~= 1 then
        return
      end
    end
    relocate(messages, threads, function(account, own, root)
      if in_trash(account, own, root) then
        return nil
      end
      return account.trash
    end, "Deleting")
  end,
  undo = function()
    local undo = state.undo or error("nothing to undo", 0)
    state.undo = nil
    layout.with_busy("Undoing", function()
      maildir.undo(undo.journal)
      notmuch.reindex()
      retag_inbox(undo.into_inbox, undo.out_of_inbox)
    end)
    M.reload()
    sync_soon()
    vim.notify(("email.nvim: undid %s"):format(undo.label:lower()))
  end,
  move = function()
    local messages, threads, label = selection()
    local account = single_account(messages)
    local folder = async.select(maildir.folders(compose.root(account)), { prompt = "Move " .. label .. " to" })
    if folder then
      relocate(messages, threads, function()
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
        local thread = state.threads[row]
        state.marked[thread.id] = not state.marked[thread.id] or nil
      end
      list.render()
      return
    end
    local thread = list.selected()
    if not thread then
      return
    end
    state.marked[thread.id] = not state.marked[thread.id] or nil
    local row = vim.api.nvim_win_get_cursor(state.win.list)[1]
    list.render()
    vim.api.nvim_win_set_cursor(state.win.list, { math.min(row + 1, math.max(1, #state.threads)), 0 })
  end,
  mark_all = function()
    for _, thread in ipairs(state.threads) do
      state.marked[thread.id] = true
    end
    list.render()
  end,
  unmark_all = function()
    state.marked = {}
    list.render()
  end,
  attachments = function()
    local message = target()
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
        return sidebar.label(f)
      end,
    })
    if folder then
      set_folder(folder)
    end
  end,
  open = function()
    local thread = list.selected()
    if thread then
      show(thread)
    end
  end,
  quit = function()
    layout.close()
  end,
  focus_sidebar = function()
    layout.focus("sidebar")
  end,
  close_reader = function()
    layout.close_reader()
  end,
  open_link = function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(state.win.reader))
    local link = link_at(row, col)
    if not link then
      vim.notify("email.nvim: no link under the cursor")
      return
    end
    open_url(link.url)
  end,
  click_link = function()
    local pos = vim.fn.getmousepos()
    local link = pos.winid == state.win.reader and pos.line > 0 and link_at(pos.line, pos.column - 1)
    if link then
      open_url(link.url)
      return
    end
    vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "n", false)
  end,
  next_message = function()
    step_thread(1)
  end,
  prev_message = function()
    step_thread(-1)
  end,
  next_in_thread = function()
    step_in_thread(1)
  end,
  prev_in_thread = function()
    step_in_thread(-1)
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
  if vim.tbl_contains(contexts, "reader") then
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
        local section = reader.section_at(vim.api.nvim_win_get_cursor(0)[1])
        if section then
          state.current = section.message
        end
      end,
    })
  end
  if vim.tbl_contains(contexts, "list") then
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
        if M.near_end() then
          async.run(M.load_more)
        end
      end,
    })
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
