local M = {}

M.defaults = {
  accounts = {},
  renderers = {},
  alternatives = { "text/html", "text/plain" },
  send_cmd = { "msmtp", "--read-envelope-from", "--read-recipients" },
  sync_cmd = nil,
  page_size = 100,
  refresh_interval = 5000,
  downloads_dir = "~/Downloads",
  border = "rounded",
  width = 0.9,
  height = 0.9,
  sidebar_width = 30,
  list_ratio = 0.4,
  icons = { unread = "●", flagged = "★", replied = "↩", attachment = "󰁦" },
  keymaps = {
    global = {
      help = "g?",
      compose = "c",
      reply = "r",
      reply_all = "R",
      forward = "f",
      edit = "e",
      archive = "a",
      delete = "d",
      move = "m",
      toggle_unread = "u",
      toggle_flagged = "s",
      attachments = "ga",
      pipe = "|",
      search = "/",
      sync = "gs",
      next_folder = { "<Tab>", "]f" },
      prev_folder = { "<S-Tab>", "[f" },
      pick_folder = "gF",
    },
    list = {
      open = "<CR>",
      quit = "q",
      next_page = "]]",
      prev_page = "[[",
      focus_sidebar = "<C-h>",
      focus_reader = "<C-j>",
    },
    reader = {
      close_reader = "q",
      next_message = "J",
      prev_message = "K",
      focus_list = "<C-k>",
    },
    sidebar = {
      select_folder = "<CR>",
      quit = "q",
      focus_list = "<C-l>",
    },
    composer = {
      send = "<C-s>",
      discard = "<C-q>",
    },
  },
}

local function validate_account(account, i)
  local where = ("accounts[%d]"):format(i)
  for _, key in ipairs({ "name", "maildir", "from", "inbox", "sent", "drafts" }) do
    vim.validate(where .. "." .. key, account[key], "string")
  end
  vim.validate(where .. ".archive", account.archive, "string", true)
  vim.validate(where .. ".addresses", account.addresses, "table")
  vim.validate(where .. ".folders", account.folders, "table")
  if #account.addresses == 0 then
    error(where .. ".addresses must list at least one address", 0)
  end
  if #account.folders == 0 then
    error(where .. ".folders must list at least one folder", 0)
  end
  for j, folder in ipairs(account.folders) do
    vim.validate(("%s.folders[%d].name"):format(where, j), folder.name, "string")
    vim.validate(("%s.folders[%d].query"):format(where, j), folder.query, "string")
  end
end

local function validate_keymaps(keymaps, actions)
  for context, maps in pairs(keymaps) do
    local known = actions[context] or error(("keymaps.%s is not a keymap context"):format(context), 0)
    for action, lhs in pairs(maps) do
      if not known[action] then
        error(("keymaps.%s.%s is not an action"):format(context, action), 0)
      end
      if lhs ~= false and type(lhs) ~= "string" and type(lhs) ~= "table" then
        error(("keymaps.%s.%s must be a string, a list of strings or false"):format(context, action), 0)
      end
    end
  end
end

function M.resolve(opts, actions)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if opts and opts.accounts then
    config.accounts = opts.accounts
  end
  vim.validate("accounts", config.accounts, "table")
  if #config.accounts == 0 then
    error("email.nvim: setup needs at least one account", 0)
  end
  for i, account in ipairs(config.accounts) do
    validate_account(account, i)
  end
  vim.validate("renderers", config.renderers, "table")
  for ctype, renderer in pairs(config.renderers) do
    if type(renderer) ~= "function" and type(renderer) ~= "table" then
      error(("renderers[%q] must be an argv list or a function"):format(ctype), 0)
    end
  end
  vim.validate("send_cmd", config.send_cmd, "table")
  vim.validate("sync_cmd", config.sync_cmd, "table", true)
  vim.validate("page_size", config.page_size, "number")
  vim.validate("refresh_interval", config.refresh_interval, "number")
  validate_keymaps(config.keymaps, actions)
  config.downloads_dir = vim.fs.normalize(config.downloads_dir)
  return config
end

return M
