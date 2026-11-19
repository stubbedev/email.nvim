# email.nvim

Read and write email in Neovim on top of a [notmuch](https://notmuchmail.org) index.

A floating layout with folders beside the message list; an opened message takes over the whole view, in the style of
[himalaya.nvim](https://github.com/knownasnaffy/himalaya.nvim), backed by notmuch instead of the himalaya CLI, so
listing, searching and opening mail is instant on a local Maildir kept in sync by mbsync, offlineimap or similar.

- Folders are notmuch queries with live unread counts. The list shows **conversations** (notmuch threads) with
  their authors and message count; opening one shows every message in it, oldest first, with older read messages
  folded (`za` opens one) and the cursor on the first unread. Reply, forward and the other message actions apply to
  the message under the cursor; from the list they apply to the newest message of the conversation that is in the
  folder, and archive, delete and move take all of the conversation's messages that are in the folder.
- Every MIME type can go through your own **renderer**: an argv that reads the part on stdin, or a Lua function. Use
  it to turn HTML mail into Markdown, render calendar invites, and so on.
- Markdown output is **rendered**, in the style of render-markdown.nvim: headings with icons and tinted backgrounds,
  bullets, quote bars, rules, code blocks and box-drawn tables that shrink to the window and wrap inside their cells.
  Links show only their label; the URL rides on the text as a terminal hyperlink (OSC 8), so you click the label, and
  wrapping follows what you see. `gx` or a mouse click opens the link: while the message window has focus,
  email.nvim turns on Neovim's mouse in normal mode (if it was off) and restores it when you leave.
- Reply, reply all, forward (with attachments) and drafts in a normal buffer. `:w` saves a draft, `<C-s>` sends.
- Sending pipes the message to any sendmail-compatible command (`msmtp` by default), then files a copy in the
  account's Sent folder with `notmuch insert`.
- Archive, move and delete move or remove the Maildir files themselves, so your sync tool carries the change to
  the server.
- Calendar invitations get an **Invite** row; accept, decline or tentatively accept sends an iCalendar `METHOD:REPLY`
  to the organizer, threaded to the invite.
- Archive, delete, move and the unread/flagged toggles work on **several messages at once**: mark them with `v`, or
  select rows in visual mode.
- **Address completion** in `To`, `Cc`, `Bcc` and `Reply-To`, ranked from the notmuch index (people you have written to
  first): built in as `omnifunc` (`<C-x><C-o>`) and as a [blink.cmp](https://github.com/saghen/blink.cmp) source.
- **Inline images** through [snacks.image](https://github.com/folke/snacks.nvim) and the Kitty graphics protocol
  (Ghostty, kitty; inside tmux via Unicode placeholders, so images scroll and clip like text): `cid:` parts, base64
  `data:` images and attached photos are drawn where the renderer put their `![alt](src)` (for example
  `html-to-md --html --images`), attached ones after the body unless the attachment list is collapsed. Remote images
  stay off unless you opt in.
- Optional [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) file icons for attachments, and Nerd
  Font icons for folders and flags.
- Saves and opens attachments, pipes a message into a shell command (unsubscribe scripts, patch tools), and refreshes
  when the notmuch database changes.

## Requirements

- Neovim 0.11 or later
- `notmuch` with a configured database
- A sendmail-compatible command for sending, such as `msmtp`

## Setup

```lua
vim.pack.add({ "https://github.com/stubbedev/email.nvim" })

require("email").setup({
  accounts = {
    {
      name = "Work",
      maildir = "work",
      from = "Jane Doe <jane@work.example>",
      addresses = { "jane@work.example" },
      inbox = "INBOX",
      sent = "Sent",
      drafts = "Drafts",
      archive = "Archive",
      trash = "Trash",
      folders = {
        { name = "Inbox", query = "folder:work/INBOX" },
        { name = "Sent", query = "folder:work/Sent" },
      },
    },
  },
  renderers = {
    ["text/html"] = { "html-to-md", "--html" },
    ["text/calendar"] = { "html-to-md", "--calendar" },
  },
  sync_cmd = { "mbsync", "-a" },
})
```

`maildir`, `inbox`, `sent`, `drafts`, `archive` and `trash` are paths relative to the notmuch database root and to the
account's maildir respectively. `addresses` decides which account a `From:` address belongs to.

Then run `:Email`, `:EmailSearch <notmuch query>` or `:EmailCompose [address]`.

### blink.cmp

```lua
require("blink.cmp").add_source_provider("email", { name = "Email", module = "email.blink" })
require("blink.cmp").add_filetype_source("mail", "email")
```

The source only answers inside email.nvim's composer, on recipient headers.

## Options

| Option | Default | |
| --- | --- | --- |
| `accounts` | — | Required, see above |
| `searches` | `{}` | Smart folders: saved searches as `{ name, query }`, shown in a "Smart" sidebar section above the accounts, with unread counts, for example `{ name = "Unread", query = "tag:unread and tag:inbox" }` |
| `renderers` | `{}` | MIME type → argv list or `function(content, content_type) -> string`. Parts without a renderer are shown as they are |
| `alternatives` | `{ "text/html", "text/plain" }` | Preference order inside `multipart/alternative` |
| `markdown` | `types = { "text/html", "text/calendar" }` and icons | Which content types' rendered output is Markdown (others are shown verbatim), and the `headings`, `bullets`, `quote`, `link`, `email` and `image` icons |
| `send_cmd` | `{ "msmtp", "--read-envelope-from", "--read-recipients" }` | Reads the message on stdin |
| `sync_cmd` | `nil` | Run by the sync key |
| `page_size` | `100` | Messages fetched at a time; the next batch loads as the cursor nears the end of the list |
| `reader_mouse` | `true` | Enable the mouse in normal mode while the message window has focus, so a click opens links |
| `refresh_interval` | `5000` | ms between checks of the notmuch database for changes; `0` disables |
| `downloads_dir` | `~/Downloads` | Where saved attachments go |
| `layout` | `"float"` | `"float"`: a floating window over the editor. `"full"`: normal windows, like oil: the folders and list open in a tab of their own (or take over the current tab when it holds only an empty buffer, as with `nvim -c Email`) and a message opens in its own tab, titles and status in the winbar; quitting closes the tabs |
| `border`, `width`, `height`, `sidebar_width` | `"rounded"`, `0.9`, `0.9`, `30` | Float size and border, and the folders' width in both layouts |
| `images` | `{ enabled = false, remote = false, max_width = 80, max_height = 40 }` | Inline images through snacks.image (snacks.nvim must be installed, with its `image` module set up, when enabled); sizes are in cells; `remote` lets snacks fetch `http(s)` images, off by default because remote images are how senders track opens |
| `devicons` | `false` | File icons for attachments from nvim-web-devicons (must be installed when `true`) |
| `icons` | Nerd Font glyphs | `unread`, `flagged`, `replied`, `attachment`, `marked`, `invite` |
| `folder_icons` | Nerd Font glyphs | `account`, `inbox`, `sent`, `drafts`, `archive`, `junk`, `trash`, `folder`, `search`; a folder's role comes from its name |
| `keymaps` | see below | Per context, action → key, list of keys or `false` |

## Keys

The defaults follow LazyVim habits: nothing shadows flash (`s`/`S`), mini.surround (`gs`) or `<C-s>` (save, which in
the composer saves a draft); `<S-h>`/`<S-l>` and `[b`/`]b` move between folders the way they move between buffers;
`R` refreshes as in lazy.nvim and neo-tree; `<Tab>`/`<C-a>` select like a picker; `<C-h/j/k/l>` move between panes;
and the rarer actions live under `<leader>m`, so which-key lists them. Press `g?` or `?` for the live list.

| Context | Key | Action |
| --- | --- | --- |
| list and message | `c` `r` `gr` `f` `e` | compose, reply, reply all, forward, edit draft |
| | `a` `d` `m` `U` | archive, delete (to the account's `trash`; from the trash, or without one, permanently after asking), move, undo the last of these (also on marked messages or a visual selection) |
| | `u` `*` | toggle unread, toggle flagged |
| | `R` | sync (`sync_cmd`) |
| | `<S-l>` `]b` / `<S-h>` `[b` | next / previous folder |
| | `<leader>/` | notmuch search |
| | `<leader>ma` `<leader>mp` `<leader>mf` | attachments, pipe to a command, pick folder |
| | `<leader>my` `<leader>mn` `<leader>mt` | accept, decline, tentatively accept an invite |
| list | `<CR>` `q` | open, quit (more messages load as you scroll) |
| | `<Tab>` `<C-a>` `<Esc>` | toggle mark (or the visual selection), mark the page, clear marks |
| | `<C-h>` | focus folders |
| message | `q` `]]` `[[` `]m` `[m` `gx` click | back to the list, next and previous conversation, next and previous message in it, open the link under the cursor or the mouse |
| folders | `<CR>` `q` `<C-l>` | open folder, quit, focus list |
| composer | `<leader>ms` `<leader>md` `:w` | send, discard, save draft |

## Highlights

`EmailUnread`, `EmailFlagged`, `EmailReplied`, `EmailAttachment`, `EmailSender`, `EmailSenderUnread`,
`EmailSubject`, `EmailSubjectUnread`, `EmailDate`, `EmailAccount`, `EmailFolder`, `EmailFolderActive`, `EmailCount`,
`EmailHeader`, `EmailSeparator`, `EmailMarked`, `EmailMarker`, `EmailFolderIcon`, `EmailAccountIcon`, `EmailInvite`,
`EmailLink`, `EmailStrong`, `EmailEmph`, `EmailCode`, `EmailCodeBlock`, `EmailImage`, `EmailBullet`, `EmailQuote`,
`EmailRule`, `EmailTableBorder`, `EmailTableHeader`, `EmailH1`–`EmailH6` and `EmailH1Bg`–`EmailH6Bg` (the backgrounds
are blended from the heading colours unless you define them).

## Development

```sh
nvim --clean -l tests/run.lua
stylua --check .
```

The end-to-end test builds a throwaway notmuch database, so `notmuch` must be on `PATH`.
