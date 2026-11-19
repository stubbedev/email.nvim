local M = {}

M.ns = vim.api.nvim_create_namespace("email.nvim")

local GROUPS = {
  EmailUnread = { link = "DiagnosticInfo" },
  EmailFlagged = { link = "DiagnosticWarn" },
  EmailReplied = { link = "Comment" },
  EmailAttachment = { link = "Special" },
  EmailSender = { link = "Identifier" },
  EmailSenderUnread = { link = "Title" },
  EmailSubject = { link = "Normal" },
  EmailSubjectUnread = { bold = true },
  EmailDate = { link = "Comment" },
  EmailAccount = { link = "Title" },
  EmailFolder = { link = "Normal" },
  EmailFolderActive = { link = "CursorLineNr" },
  EmailCount = { link = "DiagnosticInfo" },
  EmailHeader = { link = "Label" },
  EmailSeparator = { link = "FloatBorder" },
  EmailMarked = { link = "Visual" },
  EmailMarker = { link = "DiagnosticHint" },
  EmailFolderIcon = { link = "Special" },
  EmailAccountIcon = { link = "Function" },
  EmailInvite = { link = "DiagnosticOk" },
  EmailStrong = { bold = true },
  EmailEmph = { italic = true },
  EmailCode = { link = "@markup.raw" },
  EmailCodeBlock = { link = "CursorLine" },
  EmailImage = { link = "Special" },
  EmailBullet = { link = "@markup.list" },
  EmailQuote = { link = "@markup.quote" },
  EmailRule = { link = "FloatBorder" },
  EmailTableBorder = { link = "FloatBorder" },
  EmailTableHeader = { bold = true },
  EmailWinbarTitle = { link = "Title" },
}

local HEADING_BLEND = 0.2

local function color(name, key)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return hl[key]
end

local function blend(fg, bg, alpha)
  local function channel(shift)
    local f, b = bit.band(bit.rshift(fg, shift), 0xff), bit.band(bit.rshift(bg, shift), 0xff)
    return bit.lshift(math.floor(f * alpha + b * (1 - alpha) + 0.5), shift)
  end
  return bit.bor(channel(16), channel(8), channel(0))
end

local function derived()
  local groups = {}
  local link_fg = color("@markup.link.label", "fg") or color("Underlined", "fg")
  groups.EmailLink = { fg = link_fg, underline = true }
  local background = color("Normal", "bg")
  for level = 1, 6 do
    local heading = "@markup.heading." .. level .. ".markdown"
    local fg = color(heading, "fg") or color("Title", "fg")
    groups["EmailH" .. level] = { fg = fg, bold = true }
    groups["EmailH" .. level .. "Bg"] = (fg and background) and { bg = blend(fg, background, HEADING_BLEND) }
      or { link = "CursorLine" }
  end
  return groups
end

local function apply_groups(groups)
  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

function M.setup()
  apply_groups(GROUPS)
  apply_groups(derived())
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("email.nvim.highlight", { clear = true }),
    callback = function()
      apply_groups(GROUPS)
      apply_groups(derived())
    end,
  })
end

function M.apply(buf, row, highlights)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, hl[1], { end_col = hl[2], hl_group = hl[3] })
  end
end

return M
