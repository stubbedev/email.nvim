local async = require("email.async")
local compose = require("email.compose")
local composer = require("email.ui.composer")
local engine = require("email.engine")
local format = require("email.format")
local help = require("email.ui.help")
local images = require("email.images")
local layout = require("email.ui.layout")
local list = require("email.ui.list")
local markdown = require("email.markdown")
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
  attach = "Attach files",
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
  local counts = engine.counts(queries)
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
  local threads, total = engine.threads(query(), 0, math.max(state.config.page_size, #state.threads), true)
  if generation ~= state.load_generation or not layout.is_open() then
    return
  end
  state.total = total
  state.threads = threads
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
    local threads = engine.threads(query(), #state.threads, state.config.page_size, false)
    if generation ~= state.load_generation or not layout.is_open() then
      return
    end
    local known = {}
    for _, thread in ipairs(state.threads) do
      known[thread.id] = true
    end
    for _, thread in ipairs(threads) do
      if not known[thread.id] then
        state.threads[#state.threads + 1] = thread
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
  return engine.message(engine.newest_message(thread.id, query()))
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

local function preferred()
  return state.folder.account or 0
end

local function selection()
  if reading() then
    return { state.current.id }, {}, ("%q"):format(format.oneline(state.current.headers.Subject))
  end
  local threads = selected_threads()
  local ids = {}
  for _, thread in ipairs(threads) do
    vim.list_extend(ids, thread.message_ids)
  end
  local label = #threads == 1 and ("%q"):format(format.oneline(threads[1].headers.Subject))
    or ("%d conversations"):format(#threads)
  return ids, threads, label
end

local function toggle_tag(tag)
  local ids, threads = selection()
  local any = reading() and state.current.tags[tag] == true
  for _, thread in ipairs(threads) do
    any = any or thread.tags[tag] == true
  end
  local change = (any and "-" or "+") .. tag
  engine.tag(ids, { change })
  if reading() then
    state.current.tags[tag] = not any or nil
  end
  state.marked = {}
  M.load_list()
  M.refresh_counts()
end

local function invite_of(message)
  local calendar = message.calendars[1]
  return calendar and { summary = calendar.summary, method = calendar.method }
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
  local entries, unread, buf = {}, {}, nil
  layout.with_busy("Opening", function()
    for _, message in ipairs(engine.thread(thread.id)) do
      entries[#entries + 1] = { message = message, doc = render_message(message), invite = invite_of(message) }
      if message.tags.unread then
        unread[#unread + 1] = message.id
      end
    end
    state.thread = thread.id
    local focus
    buf, focus = reader.show(thread.id, entries)
    state.current = focus
    if not vim.b[buf].email_bound then
      M.bind(buf, { "global", "reader" })
      vim.b[buf].email_bound = true
    end
  end)
  layout.focus("reader")
  local pending = {}
  if state.config.images.enabled then
    for index, entry in ipairs(entries) do
      if #entry.doc.images > 0 then
        pending[#pending + 1] =
          { message = entry.message, references = entry.doc.images, first_row = state.sections[index].body }
      end
    end
  end
  if #unread > 0 then
    engine.tag(unread, { "-unread" })
    for _, entry in ipairs(entries) do
      entry.message.tags.unread = nil
    end
    thread.tags.unread = nil
    list.render()
    M.refresh_counts()
  end
  if #pending > 0 and state.thread == thread.id then
    images.show(pending, buf)
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

local function relocate(ids, threads, action, folder, label)
  local affected = {}
  for _, thread in ipairs(threads) do
    affected[thread.id] = true
  end
  local keep = neighbour(affected)
  local undo
  layout.with_busy(label, function()
    undo = engine.relocate(ids, action, folder, vim.fn.tempname(), preferred())
  end)
  state.undo = { label = label, data = undo }
  state.marked = {}
  if state.reading then
    layout.close_reader()
  end
  M.reload(keep)
  sync_soon()
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

local function read_file(path)
  local fd, err = io.open(path, "rb")
  if not fd then
    error(("read %s: %s"):format(path, err), 0)
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

local function pipe_to(message, cmd)
  local file = message.files[1] or error(("message %s has no file"):format(message.id), 0)
  local res = async.system(cmd, { stdin = read_file(file), text = true })
  local output = vim.trim((res.stdout or "") .. (res.stderr or ""))
  vim.notify(
    output ~= "" and output or ("`%s` exited %d"):format(table.concat(cmd, " "), res.code),
    res.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
  )
end

local function open_composer(draft)
  composer.open(
    draft,
    { send = compose.send, save = compose.save, attach = compose.attach },
    state.config.keymaps.composer,
    state.config.border
  )
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
    local ids, threads = selection()
    relocate(ids, threads, "archive", nil, "Archiving")
  end,
  delete = function()
    local ids, threads, label = selection()
    if engine.permanent_delete(ids, preferred()) then
      local question = ("Permanently delete %s?"):format(label)
      if vim.fn.confirm(question, "&Delete\n&Cancel", 2) ~= 1 then
        return
      end
    end
    relocate(ids, threads, "delete", nil, "Deleting")
  end,
  undo = function()
    if compose.cancel_send() then
      return
    end
    local undo = state.undo or error("nothing to undo", 0)
    state.undo = nil
    layout.with_busy("Undoing", function()
      engine.undo(undo.data)
    end)
    M.reload()
    sync_soon()
    vim.notify(("email.nvim: undid %s"):format(undo.label:lower()))
  end,
  move = function()
    local ids, threads, label = selection()
    local folder = async.select(engine.folders(ids, preferred()), { prompt = "Move " .. label .. " to" })
    if folder then
      relocate(ids, threads, "move", folder, "Moving")
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
    local filename = attachment.filename:gsub("/", "_")
    if choice == "Save" then
      vim.fn.mkdir(state.config.downloads_dir, "p")
      local path = unique_path(state.config.downloads_dir, filename)
      engine.extract(message.id, attachment.part, path)
      vim.notify("email.nvim: saved " .. path)
      return
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. filename
    engine.extract(message.id, attachment.part, path)
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
          local lastmod = engine.revision()
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
