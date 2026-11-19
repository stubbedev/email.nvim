# email.nvim

Read and write email in Neovim on top of a [notmuch](https://notmuchmail.org) index.

A floating layout with folders beside the message list; an opened message takes over the whole view, in the style of
[himalaya.nvim](https://github.com/knownasnaffy/himalaya.nvim), backed by notmuch instead of the himalaya CLI, so
listing, searching and opening mail is instant on a local Maildir kept in sync by mbsync, offlineimap or similar.

The Lua side is only the interface. Everything else runs in **email-engine**, a Go program in [`engine/`](engine) that
the plugin starts once and talks to over a pipe. It reads the index through libnotmuch, so there is no `notmuch`
process per action. It parses MIME and renders HTML, plain text and calendar parts as Markdown, moves Maildir files
and updates the index, and builds and sends mail over SMTP. Nothing but notmuch has to be installed.

- Folders are notmuch queries with live unread counts. The list shows **conversations** (notmuch threads) with
  their authors and message count; opening one shows every message in it, oldest first, with older read messages
  folded (`za` opens one) and the cursor on the first unread. Reply, forward and the other message actions apply to
  the message under the cursor; from the list they apply to the newest message of the conversation that is in the
  folder, and archive, delete and move take all of the conversation's messages that are in the folder.
- HTML mail is **rendered as clean Markdown** by the engine: layout tables, Outlook conditionals, hidden preheaders,
  tracking parameters and decorative links are stripped. `format=flowed` text is dewrapped, and calendar parts render
  as an event summary. Any MIME type can still go to your own **renderer** instead, an argv that reads the part on
  stdin or a Lua function.
- Markdown output is **rendered**, in the style of render-markdown.nvim: headings with icons and tinted backgrounds,
  bullets, quote bars, rules, code blocks and box-drawn tables that shrink to the window and wrap inside their cells.
  Links show only their label; the URL rides on the text as a terminal hyperlink (OSC 8), so you click the label, and
  wrapping follows what you see. `gx` or a mouse click opens the link: while the message window has focus,
  email.nvim turns on Neovim's mouse in normal mode (if it was off) and restores it when you leave.
- Reply, reply all, forward (with attachments) and drafts in a normal buffer. `:w` saves a draft, `<C-s>` sends.
- Sending goes **straight to the account's SMTP server** (STARTTLS or TLS, PLAIN or LOGIN auth, the password from a
  command), with an optional delay you can undo. Sent mail carries an HTML alternative made from the Markdown you
  wrote. A copy is filed in the account's Sent folder and indexed at once.
- Archive, move and delete move or remove the Maildir files themselves and update the index for exactly those files,
  so your sync tool carries the change to the server.
- Calendar invitations get an **Invite** row; accept, decline or tentatively accept sends an iCalendar `METHOD:REPLY`
  to the organizer, threaded to the invite.
- Archive, delete, move and the unread/flagged toggles work on **several messages at once**: mark them with `v`, or
  select rows in visual mode.
- **Address completion** in `To`, `Cc`, `Bcc` and `Reply-To`, ranked from the notmuch index (people you have written to
  first): built in as `omnifunc` (`<C-x><C-o>`) and as a [blink.cmp](https://github.com/saghen/blink.cmp) source.
- **Inline images** through [snacks.image](https://github.com/folke/snacks.nvim) and the Kitty graphics protocol
  (Ghostty, kitty; inside tmux via Unicode placeholders, so images scroll and clip like text): `cid:` parts, base64
  `data:` images and attached photos are drawn where the message puts them, attached ones after the body unless the
  attachment list is collapsed. Remote images stay off unless you opt in.
- Optional [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) file icons for attachments, and Nerd
  Font icons for folders and flags.
- Saves and opens attachments, pipes a message into a shell command (unsubscribe scripts, patch tools), and refreshes
  when the notmuch database changes.
- `email-engine mcp` is a **Model Context Protocol server** over the same index, so AI agents can search, read, tag
  and extract attachments (never send, move or delete).

## Requirements

- Neovim 0.11 or later
- notmuch (libnotmuch 5) with a configured database
- `curl`, once, unless you build the engine yourself (see [The engine](#the-engine))

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
      smtp = {
        host = "smtp.work.example",
        port = 587,
        security = "starttls",
        user = "jane@work.example",
        password_cmd = { "pass", "show", "mail/work" },
      },
    },
  },
  sync_cmd = { "mbsync", "-a" },
})
```

`smtp.security` is `"starttls"`, `"tls"` (implicit TLS, usually port 465) or `"none"` (a local relay; credentials are
never sent unencrypted). `smtp.auth` picks `"plain"` or `"login"` when the server's own preference does not work; by
default the engine uses PLAIN when offered and LOGIN otherwise. `password_cmd` is an argv whose first line of output is
the password; leave out `user` and `password_cmd` for a server without authentication.

An optional `signature` is added below a `-- ` line in new mail, and above the quote in replies and forwards.
`maildir`, `inbox`, `sent`, `drafts`, `archive` and `trash` are paths relative to the notmuch database root and to the
account's maildir respectively. `addresses` decides which account a `From:` address belongs to.

Then run `:Email`, `:EmailSearch <notmuch query>`, `:EmailOpen <notmuch query>` (opens the newest matching
conversation straight away, for example `thread:0000000000003285` from a notification) or
`:EmailCompose [address]`.

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
| `renderers` | `{}` | MIME type → argv list or `function(content, content_type) -> string`, replacing the engine's rendering for that type (built in: `text/html`, `text/plain`, `text/calendar`; other types are shown as they are) |
| `alternatives` | `{ "text/html", "text/plain" }` | Preference order inside `multipart/alternative` |
| `markdown` | `types = { "text/html", "text/calendar" }` and icons | Which content types' rendered output is Markdown (others are shown verbatim), and the `headings`, `bullets`, `quote`, `link`, `email` and `image` icons |
| `engine` | `nil` | Path to an `email-engine` binary to use instead of the bundled or downloaded one |
| `send_delay` | `0` | Seconds a sent message waits before it goes out; the undo key brings the composer back meanwhile, and quitting Neovim sends it at once |
| `html_alternative` | `true` | Sent mail carries the body rendered from Markdown to HTML (GitHub tables, autolinks, strikethrough, line breaks kept, raw HTML left out) as an alternative to the plain text; drafts stay plain |
| `attach_picker` | `nil` | `function(add)` that calls `add(paths)`, for a file picker of your choice; without it the attach key prompts with file completion |
| `sync_cmd` | `nil` | Run by the sync key |
| `page_size` | `100` | Messages fetched at a time; the next batch loads as the cursor nears the end of the list |
| `reader_mouse` | `true` | Enable the mouse in normal mode while the message window has focus, so a click opens links |
| `refresh_interval` | `5000` | ms between checks of the notmuch database for changes; `0` disables |
| `downloads_dir` | `~/Downloads` | Where saved attachments go |
| `layout` | `"float"` | `"float"`: a floating window over the editor. `"full"`: normal windows, like oil: the folders and list open in a tab of their own (or take over the current tab when it holds only an empty buffer, as with `nvim -c Email`) and a message opens in its own tab, titles and status in the winbar; quitting closes the tabs, and exits Neovim when nothing else is open in it |
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
| composer | `<leader>ms` `<leader>ma` `<leader>md` `:w` | send, attach files, discard, save draft |

## Highlights

`EmailUnread`, `EmailFlagged`, `EmailReplied`, `EmailAttachment`, `EmailSender`, `EmailSenderUnread`,
`EmailSubject`, `EmailSubjectUnread`, `EmailDate`, `EmailAccount`, `EmailFolder`, `EmailFolderActive`, `EmailCount`,
`EmailHeader`, `EmailSeparator`, `EmailMarked`, `EmailMarker`, `EmailFolderIcon`, `EmailAccountIcon`, `EmailInvite`,
`EmailLink`, `EmailStrong`, `EmailEmph`, `EmailCode`, `EmailCodeBlock`, `EmailImage`, `EmailBullet`, `EmailQuote`,
`EmailRule`, `EmailTableBorder`, `EmailTableHeader`, `EmailH1`–`EmailH6` and `EmailH1Bg`–`EmailH6Bg` (the backgrounds
are blended from the heading colours unless you define them).

## The engine

email.nvim looks for `email-engine` in this order:

1. the `engine` option;
2. `bin/email-engine` inside the plugin, which the Nix package ships and `go build -o ../bin/email-engine
   ./cmd/email-engine` (run in `engine/`) produces;
3. a release binary for the plugin's `engine/VERSION`, downloaded on first use from this repository's GitHub releases
   into `stdpath("data")/email.nvim/` and checked against the release's SHA-256 sums. Prebuilt binaries exist for
   Linux (x86-64, arm64) and macOS (arm64) and link against the system's libnotmuch.

The plugin refuses an engine whose version differs from `engine/VERSION`, so the Lua and the engine never drift apart.

### Nix

The flake's default package, `vim-plugin`, is the plugin with the engine built from the same commit in its `bin/`.
Put it on the runtimepath and nothing is downloaded:

```nix
inputs.email-nvim.url = "github:stubbedev/email.nvim";
# then, for example
programs.neovim.plugins = [ inputs.email-nvim.packages.${pkgs.stdenv.hostPlatform.system}.vim-plugin ];
```

`packages.email-engine` is the engine alone.

### Commands

| Command | |
| --- | --- |
| `email-engine serve` | email.nvim's backend: one JSON request per line on stdin, one response per line on stdout |
| `email-engine mcp` | A Model Context Protocol server on stdio, with the tools `notmuch_search`, `notmuch_show`, `notmuch_extract`, `notmuch_count`, `notmuch_tags` and `notmuch_tag`. Attachments are written under `$XDG_CACHE_HOME/email-engine/attachments` (or `EMAIL_ENGINE_ATTACHMENT_DIR`), never returned inline |
| `email-engine convert [--html [--images] \| --plain [--flowed] \| --calendar]` | Render one part from stdin as Markdown; without a flag the part is sniffed (`BEGIN:VCALENDAR`, HTML markers, else plain text) |
| `email-engine convert --to-html` | The reverse: Markdown from stdin as an HTML fragment |
| `email-engine version` | |

An MCP client entry looks like `{ "command": "email-engine", "args": ["mcp"] }`.

### HTML to Markdown

```
HTML ─▶ pre-process ─▶ x/net/html ─▶ clean ─▶ lower ─▶ transform ─▶ render ─▶ Markdown
```

1. **Pre-process**: strip IE conditionals (`<![if …]>…<![endif]>`, an Outlook and Word habit) before parsing.
2. **Parse** with `golang.org/x/net/html`.
3. **Clean** (`internal/clean`, `internal/table`): drop comments (Outlook's `<!--[if mso]>` blocks), namespaced, hidden
   and non-text elements; normalise invisible characters; flatten CSS flex rows and layout tables; demote stat-only
   headings; drop decorative and empty links. The pass order in `clean.Doc` matters.
4. **Lower** (`internal/lower`) the cleaned DOM into a typed Markdown AST (`internal/ast`).
5. **Transform**: remap and compress heading levels, drop empty sections, join short link rows, prune empty table
   columns.
6. **Render** (`internal/render`) in one deterministic pass: escape source text once, emit the markers, pad tables.

The output is a small dialect the reader relies on:

- One line per paragraph; the reader wraps to the window.
- Links are single-line `[text](href)`. `[url](url)` and `[email](mailto:email)` collapse to the bare string, and
  repeated links in a joined link row are dropped.
- Click-tracking parameters are removed from links (`utm_*`, `gclid`, `fbclid`, `dclid`, `msclkid`, `twclid`, `yclid`,
  `igshid`, `_hsenc`, `_hsmi`, `mc_cid`, `mc_eid`, `vero_*`, `s_kwcid`, `elqtrackid`, `gclsrc`); nothing else in a URL
  changes.
- Headings are rank-compressed: the shallowest becomes `#` and the levels present map onto `1..n`. Heading text is
  whitespace-normalised and loses its emphasis.
- `<br>` is a line break inside a paragraph and `<br><br>` a blank line; emphasis never spans a line break.
- Layout tables become paragraphs. Data tables (with `<thead>` or `<caption>`, or uniform bordered rows) become
  minimal pipe tables.
- `\`, `` ` ``, `*`, `_`, `[` and `]` in the text are backslash-escaped. Literal `\u2013`-style escapes left by
  broken templates are decoded.
- With images on, content images become `![alt](src)` (`cid:`, `http(s)` and base64 `data:image/*`). Tracking
  pixels and spacers (2px or smaller) are dropped.

`format=flowed` plain text (RFC 3676) is dewrapped: soft-wrapped lines join, quote levels become blockquotes, the
`-- ` signature stays as it is, and Outlook conditional lines leaked into the plain part are dropped.

Calendar parts render `VEVENT` and `VTODO` components as one heading, the time range (`Tue, 1 Sep 2026, 17:00 –
18:30 (Europe/Berlin)`, with all-day and `DURATION` forms), the location and organiser, attendees with their answers
(`✓` accepted, `✗` declined, `~` tentative), a readable `RRULE` and the description. A description with embedded HTML
goes through the HTML pipeline.

## Development

`nix develop` has Go, notmuch, Neovim and the linters.

```sh
(cd engine && go test -race ./... && golangci-lint run && go build -o ../bin/email-engine ./cmd/email-engine)
nvim --clean -l tests/run.lua
stylua --check .
nix flake check
```

The engine's tests and the end-to-end test build throwaway notmuch databases, so `notmuch` must be on `PATH`; the Lua
tests use the engine in `bin/`. A release is a `v<engine/VERSION>` tag, which builds the binaries the plugin downloads.
