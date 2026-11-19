local async = require("email.async")

local M = {}

local HEADER_ORDER = { "From", "To", "Cc", "Date", "Subject" }

local function text(block, renderers)
  local renderer = renderers[block.content_type]
  if renderer == nil then
    return block.content
  end
  if type(renderer) == "function" then
    return renderer(block.content, block.content_type)
  end
  return async.checked(renderer, { stdin = block.content, text = true })
end

function M.lines(s)
  local lines = vim.split((s:gsub("\r", "")), "\n", { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    lines[#lines] = nil
  end
  while #lines > 0 and vim.trim(lines[1]) == "" do
    table.remove(lines, 1)
  end
  return lines
end

function M.header_lines(headers)
  local out = {}
  for _, name in ipairs(HEADER_ORDER) do
    if headers[name] and headers[name] ~= "" then
      out[#out + 1] = name .. ": " .. headers[name]
    end
  end
  return out
end

function M.segments(message, renderers, markdown_types)
  local markdown = {}
  for _, ctype in ipairs(markdown_types) do
    markdown[ctype] = true
  end
  local out = {}
  for _, block in ipairs(message.blocks) do
    if block.kind == "headers" then
      local lines = { "---------- Attached message ----------" }
      vim.list_extend(lines, M.header_lines(block.headers))
      out[#out + 1] = { lines = lines, markdown = false }
    else
      out[#out + 1] = { lines = M.lines(text(block, renderers)), markdown = markdown[block.content_type] == true }
    end
  end
  return out
end

function M.body(message, renderers)
  local out = {}
  for _, segment in ipairs(M.segments(message, renderers, {})) do
    if #out > 0 then
      out[#out + 1] = ""
    end
    vim.list_extend(out, segment.lines)
  end
  return out
end

return M
