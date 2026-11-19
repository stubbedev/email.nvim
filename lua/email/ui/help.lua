local M = {}

local CONTEXTS = { "list", "reader", "sidebar", "global", "composer" }

local function keys(lhs)
  return type(lhs) == "table" and table.concat(lhs, " ") or lhs
end

function M.lines(keymaps, descriptions)
  local lines = {}
  for _, context in ipairs(CONTEXTS) do
    local rows = {}
    for action, lhs in pairs(keymaps[context] or {}) do
      if lhs then
        rows[#rows + 1] = { keys(lhs), descriptions[action] }
      end
    end
    table.sort(rows, function(a, b)
      return a[2] < b[2]
    end)
    if #rows > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = " " .. context:sub(1, 1):upper() .. context:sub(2)
      for _, row in ipairs(rows) do
        lines[#lines + 1] = ("   %-14s %s"):format(row[1], row[2])
      end
    end
  end
  return lines
end

function M.open(keymaps, descriptions, border)
  local lines = M.lines(keymaps, descriptions)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  local height = math.min(#lines, vim.o.lines - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = border,
    style = "minimal",
    title = " Keys ",
    title_pos = "center",
    zindex = 70,
  })
  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, function()
      vim.api.nvim_win_close(win, true)
    end, { buffer = buf, nowait = true })
  end
end

return M
