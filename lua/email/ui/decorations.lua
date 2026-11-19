local M = {}

local ns = vim.api.nvim_create_namespace("email.nvim.decorations")
local by_buf = {}

function M.rows()
  return {}
end

local function row_of(rows, row)
  local entry = rows[row]
  if not entry then
    entry = {}
    rows[row] = entry
  end
  return entry
end

function M.span(rows, row, start_col, end_col, group)
  local entry = row_of(rows, row)
  entry[#entry + 1] = { start_col, end_col, group }
end

function M.line(rows, row, group)
  row_of(rows, row).line = group
end

function M.link(rows, row, start_col, end_col, url)
  local entry = row_of(rows, row)
  entry.links = entry.links or {}
  entry.links[#entry.links + 1] = { start_col, end_col, url }
end

function M.set(buf, rows)
  if not by_buf[buf] then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        by_buf[buf] = nil
      end,
    })
  end
  by_buf[buf] = rows
end

local function paint(buf, row, entry)
  if entry.line then
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = entry.line, ephemeral = true, strict = false })
  end
  for _, span in ipairs(entry) do
    vim.api.nvim_buf_set_extmark(
      buf,
      ns,
      row,
      span[1],
      { end_col = span[2], hl_group = span[3], ephemeral = true, strict = false }
    )
  end
  for _, link in ipairs(entry.links or {}) do
    vim.api.nvim_buf_set_extmark(
      buf,
      ns,
      row,
      link[1],
      { end_col = link[2], url = link[3], ephemeral = true, strict = false }
    )
  end
end

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf)
    return by_buf[buf] ~= nil
  end,
  on_line = function(_, _, buf, row)
    local entry = by_buf[buf][row]
    if entry then
      paint(buf, row, entry)
    end
  end,
})

return M
