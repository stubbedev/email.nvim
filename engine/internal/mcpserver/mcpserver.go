package mcpserver

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/stubbedev/email.nvim/engine/internal/engine"
	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
	"github.com/stubbedev/email.nvim/engine/internal/view"
)

const (
	defaultLimit       = 20
	defaultMaxBody     = 4000
	maxAttachmentBytes = 100 << 20
	htmlSeparator      = "\n\n--- rendered HTML ---\n\n"
)

var (
	plainFirst = []string{"text/plain", "text/html"}
	htmlFirst  = []string{"text/html", "text/plain"}
)

func Run(ctx context.Context, version string) error {
	e, err := engine.New(engine.Config{Alternatives: plainFirst})
	if err != nil {
		return err
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "email-engine mcp", Version: version}, nil)
	addTools(server, e)
	if err := server.Run(ctx, &mcp.StdioTransport{}); err != nil {
		return fmt.Errorf("mcp server: %w", err)
	}
	return nil
}

type searchArgs struct {
	Query  string `json:"query" jsonschema:"notmuch query, e.g. 'tag:inbox and from:alice' or 'subject:invoice and date:last_week..'"`
	Limit  int    `json:"limit,omitempty" jsonschema:"max threads to return (default 20)"`
	Offset int    `json:"offset,omitempty" jsonschema:"skip this many threads, for paging"`
	Sort   string `json:"sort,omitempty" jsonschema:"newest-first (default) or oldest-first"`
}

type showArgs struct {
	Query        string `json:"query" jsonschema:"notmuch query selecting the messages to read; id:<message-id> reads one message"`
	Limit        int    `json:"limit,omitempty" jsonschema:"max messages to return (default 20)"`
	EntireThread bool   `json:"entire_thread,omitempty" jsonschema:"include every message in the matching threads, not just the matches"`
	IncludeHTML  bool   `json:"include_html,omitempty" jsonschema:"also render the HTML part when the message already has a plain-text body; use when that body looks like a stub. HTML-only messages are rendered automatically"`
	MaxBodyChars int    `json:"max_body_chars,omitempty" jsonschema:"truncate each body to this many bytes (default 4000, 0 for unlimited)"`
}

type extractArgs struct {
	MessageID string `json:"message_id" jsonschema:"the message's Message-ID, as returned in notmuch_show's id field (without the id: prefix)"`
	Part      int    `json:"part" jsonschema:"the part number from notmuch_show's attachments list"`
	Filename  string `json:"filename,omitempty" jsonschema:"name to save as; defaults to the attachment's own filename"`
}

type countArgs struct {
	Query  string `json:"query" jsonschema:"notmuch query to count"`
	Output string `json:"output,omitempty" jsonschema:"messages (default), threads or files"`
}

type tagsArgs struct {
	Query string `json:"query,omitempty" jsonschema:"restrict to tags used by messages matching this query (default '*', all tags)"`
}

type tagArgs struct {
	Query  string   `json:"query" jsonschema:"notmuch query selecting the messages to retag; every match is modified"`
	Add    []string `json:"add,omitempty" jsonschema:"tags to add"`
	Remove []string `json:"remove,omitempty" jsonschema:"tags to remove"`
}

type Message struct {
	ID          string            `json:"id"`
	Subject     string            `json:"subject,omitempty"`
	From        string            `json:"from,omitempty"`
	To          string            `json:"to,omitempty"`
	Cc          string            `json:"cc,omitempty"`
	Date        string            `json:"date,omitempty"`
	Tags        []string          `json:"tags,omitempty"`
	Attachments []view.Attachment `json:"attachments,omitempty"`
	Body        string            `json:"body,omitempty"`
}

func addTools(s *mcp.Server, e *engine.Engine) {
	mcp.AddTool(s, &mcp.Tool{
		Name:        "notmuch_search",
		Description: "Search mail. Returns one JSON summary per matching thread (subject, authors, tags, date, thread id, matched message ids) — not message bodies. Use notmuch_show to read them.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, a searchArgs) (*mcp.CallToolResult, any, error) {
		if err := checkQuery(a.Query); err != nil {
			return nil, nil, err
		}
		sort := notmuch.NewestFirst
		switch a.Sort {
		case "", "newest-first":
		case "oldest-first":
			sort = notmuch.OldestFirst
		default:
			return nil, nil, fmt.Errorf("sort must be newest-first or oldest-first, got %q", a.Sort)
		}
		page, err := e.Threads(a.Query, sort, max(a.Offset, 0), limitOr(a.Limit), false)
		if err != nil {
			return nil, nil, err
		}
		return jsonResult(page.Threads)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "notmuch_show",
		Description: "Read messages matching a query. Returns flattened messages: headers, tags, plain-text body, and an attachments list (part number, filename, type, size). " +
			"Attachment bytes are never returned inline — call notmuch_extract with the part number to write one to disk.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, a showArgs) (*mcp.CallToolResult, any, error) {
		if err := checkQuery(a.Query); err != nil {
			return nil, nil, err
		}
		maxBody := defaultMaxBody
		if a.MaxBodyChars != 0 {
			maxBody = a.MaxBodyChars
		}
		views, err := e.Matching(a.Query, limitOr(a.Limit), a.EntireThread, plainFirst)
		if err != nil {
			return nil, nil, err
		}
		out := make([]Message, len(views))
		for i, v := range views {
			body := text(v.Blocks)
			if a.IncludeHTML {
				html, err := e.Message(v.ID, htmlFirst)
				if err != nil {
					return nil, nil, err
				}
				if rendered := text(html.Blocks); rendered != body {
					body += htmlSeparator + rendered
				}
			}
			out[i] = Message{
				ID: v.ID, Subject: v.Headers["Subject"], From: v.Headers["From"], To: v.Headers["To"],
				Cc: v.Headers["Cc"], Date: v.Headers["Date"], Tags: v.Tags, Attachments: v.Attachments,
				Body: truncate(body, maxBody),
			}
		}
		return jsonResult(out)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "notmuch_extract",
		Description: "Write one attachment (any file type — PDF, image, zip, spreadsheet, anything) to a file on disk and return its path. " +
			"The bytes go to disk, not through this conversation, so read or process the returned path with your own file tools. " +
			"Get message_id and part from notmuch_show's attachments list.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, a extractArgs) (*mcp.CallToolResult, any, error) {
		path, n, err := extract(e, a)
		if err != nil {
			return nil, nil, err
		}
		return textResult(fmt.Sprintf("wrote %d bytes to %s", n, path)), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "notmuch_count",
		Description: "Count messages, threads or files matching a query. Cheap way to size a query before showing it.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, a countArgs) (*mcp.CallToolResult, any, error) {
		if err := checkQuery(a.Query); err != nil {
			return nil, nil, err
		}
		output := engine.Output(a.Output)
		if output == "" {
			output = engine.Messages
		}
		n, err := e.Count(a.Query, output)
		if err != nil {
			return nil, nil, err
		}
		return textResult(strconv.Itoa(n)), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "notmuch_tags",
		Description: "List tags in use. Call this before tagging so you reuse existing tag names instead of inventing new ones.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, a tagsArgs) (*mcp.CallToolResult, any, error) {
		query := a.Query
		if query == "" {
			query = "*"
		}
		tags, err := e.Tags(query)
		if err != nil {
			return nil, nil, err
		}
		return jsonResult(tags)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "notmuch_tag",
		Description: "Add and/or remove tags on every message matching the query. This writes to the mail store. Check notmuch_count first — a broad query retags a lot of mail, and there is no undo beyond running the inverse tag call.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, a tagArgs) (*mcp.CallToolResult, any, error) {
		if err := checkQuery(a.Query); err != nil {
			return nil, nil, err
		}
		changes, err := tagChanges(a.Add, a.Remove)
		if err != nil {
			return nil, nil, err
		}
		n, err := e.TagMatching(a.Query, changes)
		if err != nil {
			return nil, nil, err
		}
		return textResult(fmt.Sprintf("tagged %d messages matching %q (add=%v remove=%v)", n, a.Query, a.Add, a.Remove)), nil, nil
	})
}

func text(blocks []view.Block) string {
	parts := make([]string, 0, len(blocks))
	for _, b := range blocks {
		if b.Kind == view.TextBlock && strings.TrimSpace(b.Content) != "" {
			parts = append(parts, strings.TrimSpace(b.Content))
		}
	}
	return strings.Join(parts, "\n\n")
}

func tagChanges(add, remove []string) ([]string, error) {
	if len(add) == 0 && len(remove) == 0 {
		return nil, errors.New("provide at least one tag in add or remove")
	}
	changes := make([]string, 0, len(add)+len(remove))
	for _, group := range []struct {
		sign string
		tags []string
	}{{"+", add}, {"-", remove}} {
		for _, tag := range group.tags {
			if err := checkTag(tag); err != nil {
				return nil, err
			}
			changes = append(changes, group.sign+tag)
		}
	}
	return changes, nil
}

func checkQuery(q string) error {
	if strings.TrimSpace(q) == "" {
		return errors.New(`query must not be empty (use "*" to match every message)`)
	}
	return nil
}

func checkTag(t string) error {
	switch {
	case t == "":
		return errors.New("tag must not be empty")
	case strings.ContainsAny(t, " \t\n"):
		return fmt.Errorf("tag %q must not contain whitespace", t)
	case strings.HasPrefix(t, "-"), strings.HasPrefix(t, "+"):
		return fmt.Errorf("tag %q must not start with + or -; use the add/remove arguments", t)
	}
	return nil
}

func attachmentDir() (string, error) {
	if d := os.Getenv("EMAIL_ENGINE_ATTACHMENT_DIR"); d != "" {
		return d, nil
	}
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("locating the attachment directory: %w", err)
	}
	return filepath.Join(cache, "email-engine", "attachments"), nil
}

func safeName(name string, part int) string {
	if i := strings.LastIndexAny(name, `/\`); i >= 0 {
		name = name[i+1:]
	}
	name = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return '_'
		}
		return r
	}, name))
	if name == "" || strings.HasPrefix(name, ".") {
		ext := filepath.Ext(name)
		if ext == "." {
			ext = ""
		}
		return fmt.Sprintf("part-%d%s", part, ext)
	}
	return name
}

func extract(e *engine.Engine, a extractArgs) (string, int, error) {
	if strings.TrimSpace(a.MessageID) == "" {
		return "", 0, errors.New("message_id must not be empty")
	}
	if a.Part < 1 {
		return "", 0, fmt.Errorf("part must be 1 or greater, got %d", a.Part)
	}
	part, err := e.Part(a.MessageID, a.Part)
	if err != nil {
		return "", 0, err
	}
	if len(part.Body) == 0 {
		return "", 0, fmt.Errorf("part %d of id:%s is empty — check the part number from notmuch_show", a.Part, a.MessageID)
	}
	if len(part.Body) > maxAttachmentBytes {
		return "", 0, fmt.Errorf("part %d is %d bytes, over the %d byte limit", a.Part, len(part.Body), maxAttachmentBytes)
	}
	name := a.Filename
	if strings.TrimSpace(name) == "" {
		name = part.Filename
	}
	base, err := attachmentDir()
	if err != nil {
		return "", 0, err
	}
	sum := sha256.Sum256([]byte(a.MessageID))
	dir := filepath.Join(base, hex.EncodeToString(sum[:6]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", 0, fmt.Errorf("creating %s: %w", dir, err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return "", 0, fmt.Errorf("opening %s: %w", dir, err)
	}
	defer func() { _ = root.Close() }()
	file := safeName(name, a.Part)
	if err := root.WriteFile(file, part.Body, 0o600); err != nil {
		return "", 0, fmt.Errorf("writing %s: %w", filepath.Join(dir, file), err)
	}
	return filepath.Join(dir, file), len(part.Body), nil
}

func truncate(s string, limit int) string {
	if limit <= 0 || len(s) <= limit {
		return s
	}
	cut := limit
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + fmt.Sprintf("\n…[truncated, %d bytes total]", len(s))
}

func limitOr(n int) int {
	if n <= 0 {
		return defaultLimit
	}
	return n
}

func textResult(s string) *mcp.CallToolResult {
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: s}}}
}

func jsonResult(v any) (*mcp.CallToolResult, any, error) {
	buf, err := json.Marshal(v)
	if err != nil {
		return nil, nil, fmt.Errorf("encoding result: %w", err)
	}
	return textResult(string(buf)), nil, nil
}
