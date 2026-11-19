local actions = require("email.actions")
local async = require("email.async")
local compose = require("email.compose")
local config = require("email.config")
local highlight = require("email.ui.highlight")
local engine = require("email.engine")
local layout = require("email.ui.layout")
local sidebar = require("email.ui.sidebar")
local state = require("email.state")

local M = {}

local function configured()
  return state.config or error("email.nvim: call require('email').setup() first", 0)
end

function M.open(search, open_first)
  configured()
  if layout.is_open() then
    layout.focus("list")
  else
    state.folder = state.folder or sidebar.folders()[1]
    layout.open()
    actions.bind(state.buf.list, { "global", "list" })
    actions.bind(state.buf.sidebar, { "global", "sidebar" })
  end
  if search then
    state.folder, state.threads, state.total, state.exhausted = { search = search }, {}, nil, false
  end
  async.run(function()
    actions.reload()
    state.lastmod = engine.revision()
    actions.prefetch()
    actions.start_polling()
    if open_first then
      if #state.threads == 0 then
        error(("no conversation matches %s"):format(search), 0)
      end
      actions.handlers.open()
    end
  end)
end

function M.compose(to)
  configured()
  local account = state.folder and state.folder.account and state.config.accounts[state.folder.account]
    or state.config.accounts[1]
  actions.open_composer(compose.new(account, to))
end

function M.setup(opts)
  state.config = config.resolve(opts, actions.contexts)
  engine.stop()
  highlight.setup()
  vim.api.nvim_create_user_command("Email", function()
    M.open()
  end, { desc = "Open email.nvim" })
  vim.api.nvim_create_user_command("EmailCompose", function(args)
    M.compose(args.args ~= "" and args.args or nil)
  end, { nargs = "?", desc = "Compose an email" })
  vim.api.nvim_create_user_command("EmailSearch", function(args)
    M.open(args.args)
  end, { nargs = 1, desc = "Search email with a notmuch query" })
  vim.api.nvim_create_user_command("EmailOpen", function(args)
    M.open(args.args, true)
  end, { nargs = 1, desc = "Open the newest conversation matching a notmuch query" })
end

return M
