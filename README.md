# email.nvim

Read and write email in Neovim on top of a [notmuch](https://notmuchmail.org) index.

A floating three-pane layout (folders, message list, message) in the style of
[himalaya.nvim](https://github.com/knownasnaffy/himalaya.nvim), backed by notmuch instead of the himalaya CLI, so
listing, searching and opening mail is instant on a local Maildir kept in sync by mbsync, offlineimap or similar.

- Folders are notmuch queries with live unread counts.
- Every MIME type can go through your own **renderer**: an argv that reads the part on stdin, or a Lua function. Use
  it to turn HTML mail into Markdown, render calendar invites, and so on. The reader shows Markdown with treesitter
  highlighting and concealed links.
- Reply, reply all, forward (with attachments) and drafts in a normal buffer. `:w` saves a draft, `<C-s>` sends.
- Sending pipes the message to any sendmail-compatible command (`msmtp` by default), then files a copy in the
  account's Sent folder with `notmuch insert`.
- Archive, move and delete move or remove the Maildir files themselves, so your sync tool carries the change to
  the server.
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

`maildir`, `inbox`, `sent`, `drafts` and `archive` are paths relative to the notmuch database root and to the
account's maildir respectively. `addresses` decides which account a `From:` address belongs to.

Then run `:Email`, `:EmailSearch <notmuch query>` or `:EmailCompose [address]`.

## Options

| Option | Default | |
| --- | --- | --- |
| `accounts` | — | Required, see above |
| `renderers` | `{}` | MIME type → argv list or `function(content, content_type) -> string`. Parts without a renderer are shown as they are |
| `alternatives` | `{ "text/html", "text/plain" }` | Preference order inside `multipart/alternative` |
| `send_cmd` | `{ "msmtp", "--read-envelope-from", "--read-recipients" }` | Reads the message on stdin |
| `sync_cmd` | `nil` | Run by the sync key |
| `page_size` | `100` | Messages per page |
| `refresh_interval` | `5000` | ms between checks of the notmuch database for changes; `0` disables |
| `downloads_dir` | `~/Downloads` | Where saved attachments go |
| `border`, `width`, `height`, `sidebar_width`, `list_ratio` | `"rounded"`, `0.9`, `0.9`, `30`, `0.4` | Layout |
| `icons` | `● ★ ↩ 󰁦` | `unread`, `flagged`, `replied`, `attachment` |
| `keymaps` | see below | Per context, action → key, list of keys or `false` |

## Keys

Press `g?` inside the client for the live list.

| Context | Key | Action |
| --- | --- | --- |
| everywhere | `c` `r` `R` `f` `e` | compose, reply, reply all, forward, edit draft |
| | `a` `d` `m` | archive, delete, move |
| | `u` `s` | toggle unread, toggle flagged |
| | `ga` `\|` | open or save attachment, pipe message to a command |
| | `/` `gs` | notmuch search, sync |
| | `<Tab>` `<S-Tab>` `gF` | next, previous, pick folder |
| list | `<CR>` `q` `]]` `[[` | open, quit, next and previous page |
| message | `q` `J` `K` | close, next and previous message |
| folders | `<CR>` | open folder |
| composer | `<C-s>` `<C-q>` `:w` | send, discard, save draft |

## Highlights

`EmailUnread`, `EmailFlagged`, `EmailReplied`, `EmailAttachment`, `EmailSender`, `EmailSenderUnread`,
`EmailSubject`, `EmailSubjectUnread`, `EmailDate`, `EmailAccount`, `EmailFolder`, `EmailFolderActive`, `EmailCount`,
`EmailHeader`, `EmailSeparator`.

## Development

```sh
nvim --clean -l tests/run.lua
stylua --check .
```

The end-to-end test builds a throwaway notmuch database, so `notmuch` must be on `PATH`.
