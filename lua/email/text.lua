local M = {}

M.CHAR = "[%z\1-\127\194-\244][\128-\191]*"

function M.width(s)
  if not s:find("[^\32-\126]") then
    return #s
  end
  if s:find("%c") then
    return vim.fn.strdisplaywidth(s)
  end
  return vim.api.nvim_strwidth(s)
end

function M.fit(s, width)
  local w = M.width(s)
  if w <= width then
    return s .. string.rep(" ", width - w)
  end
  if not s:find("[^\32-\126]") then
    return s:sub(1, width - 1) .. "…"
  end
  local out, used = {}, 0
  for ch in s:gmatch(M.CHAR) do
    local cw = M.width(ch)
    if used + cw > width - 1 then
      break
    end
    out[#out + 1] = ch
    used = used + cw
  end
  return table.concat(out) .. "…" .. string.rep(" ", width - 1 - used)
end

return M
