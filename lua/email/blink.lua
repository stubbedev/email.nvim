local addresses = require("email.addresses")
local async = require("email.async")

local source = {}

local EMPTY = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }

function source.new()
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return vim.b.email_composer == true
end

function source:get_completions(ctx, callback)
  local row, col = ctx.cursor[1], ctx.cursor[2]
  local start = addresses.at_cursor(ctx.bufnr, row, col)
  if not start then
    callback(EMPTY)
    return
  end
  async.run(function()
    local kind = require("blink.cmp.types").CompletionItemKind.Text
    local items = {}
    for i, entry in ipairs(addresses.load()) do
      local text = entry.display
      items[i] = {
        label = text,
        kind = kind,
        filterText = (entry.name or "") .. " " .. entry.addr,
        sortText = ("%06d"):format(i),
        textEdit = {
          newText = text,
          range = { start = { line = row - 1, character = start }, ["end"] = { line = row - 1, character = col } },
        },
      }
    end
    callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
  end)
end

return source
