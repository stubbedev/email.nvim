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
  local n = #entry
  entry[n + 1], entry[n + 2], entry[n + 3] = start_col, end_col, group
end

function M.entry(rows, row)
  local entry = {}
  rows[row] = entry
  return entry
end

function M.line(rows, row, group)
  row_of(rows, row).line = group
end

function M.link(rows, row, start_col, end_col, url)
  local entry = row_of(rows, row)
  local links = entry.links or {}
  entry.links = links
  local n = #links
  links[n + 1], links[n + 2], links[n + 3] = start_col, end_col, url
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

local set_extmark = vim.api.nvim_buf_set_extmark
local line_opts = { ephemeral = true, strict = false }
local span_opts = { ephemeral = true, strict = false }
local link_opts = { ephemeral = true, strict = false }

local function paint(buf, row, entry)
  if entry.line then
    line_opts.line_hl_group = entry.line
    set_extmark(buf, ns, row, 0, line_opts)
  end
  for i = 1, #entry, 3 do
    span_opts.end_col, span_opts.hl_group = entry[i + 1], entry[i + 2]
    set_extmark(buf, ns, row, entry[i], span_opts)
  end
  local links = entry.links
  if links then
    for i = 1, #links, 3 do
      link_opts.end_col, link_opts.url = links[i + 1], links[i + 2]
      set_extmark(buf, ns, row, links[i], link_opts)
    end
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
