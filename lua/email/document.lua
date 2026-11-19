local async = require("email.async")
local engine = require("email.engine")
local state = require("email.state")

local M = {}

M.QUOTE = { width = 72, inline_urls = true }
M.PLAIN = { width = 0, plain = true }

local function rendered(block)
  local renderer = state.config.renderers[block.content_type]
  if block.kind ~= "text" or renderer == nil then
    return block
  end
  local content
  if type(renderer) == "function" then
    content = renderer(block.content, block.content_type)
  else
    content = async.checked(renderer, { stdin = block.content, text = true })
  end
  return { kind = block.kind, content_type = block.content_type, content = content }
end

function M.of(message, render)
  if message.doc then
    return message.doc
  end
  return engine.render(vim.tbl_map(rendered, message.blocks), render)
end

function M.lines(id, alternatives, render)
  return M.of(engine.message(id, alternatives, render), render).lines
end

return M
