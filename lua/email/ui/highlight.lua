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
}

function M.setup()
  for name, spec in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end

function M.apply(buf, row, highlights)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, hl[1], { end_col = hl[2], hl_group = hl[3] })
  end
end

return M
