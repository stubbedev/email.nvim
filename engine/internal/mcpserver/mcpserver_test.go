package mcpserver

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/stubbedev/email.nvim/engine/internal/engine"
	"github.com/stubbedev/email.nvim/engine/internal/mailtest"
)

func session(t *testing.T) *mcp.ClientSession {
	t.Helper()
	mailtest.Setup(t, map[string]string{
		"INBOX/new/1": strings.Join([]string{
			"From: Alice <alice@example.com>", "To: me@example.com", "Subject: Invoice", "Message-ID: <inv@example.com>",
			`Content-Type: multipart/mixed; boundary="b"`, "",
			"--b", `Content-Type: multipart/alternative; boundary="a"`, "",
			"--a", "Content-Type: text/plain", "", "hello there",
			"--a", "Content-Type: text/html", "", "<p>hello <b>there</b></p>",
			"--a--",
			"--b", "Content-Type: application/pdf", `Content-Disposition: attachment; filename="../../escape.pdf"`, "Content-Transfer-Encoding: base64", "", "UERG",
			"--b--", "",
		}, "\n"),
		"INBOX/new/2": mailtest.Message("html@example.com", "Billing <b@example.com>", "me@example.com", "Due", "Thu, 19 Nov 2026 10:00:00 +0000", "x"),
	})
	t.Setenv("EMAIL_ENGINE_ATTACHMENT_DIR", t.TempDir())
	e, err := engine.New(engine.Config{Alternatives: plainFirst})
	if err != nil {
		t.Fatal(err)
	}
	server := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "test"}, nil)
	addTools(server, e)
	serverSide, clientSide := mcp.NewInMemoryTransports()
	if _, err := server.Connect(t.Context(), serverSide, nil); err != nil {
		t.Fatal(err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "client", Version: "test"}, nil)
	cs, err := client.Connect(t.Context(), clientSide, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func call(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) (string, bool) {
	t.Helper()
	result, err := cs.CallTool(t.Context(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	var text strings.Builder
	for _, c := range result.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text.WriteString(tc.Text)
		}
	}
	return text.String(), result.IsError
}

func TestToolsReadTagAndExtract(t *testing.T) {
	cs := session(t)

	out, failed := call(t, cs, "notmuch_search", map[string]any{"query": "tag:inbox"})
	if failed || !strings.Contains(out, `"subject":"Invoice"`) || !strings.Contains(out, `"subject":"Due"`) {
		t.Errorf("search = %s", out)
	}

	out, failed = call(t, cs, "notmuch_show", map[string]any{"query": "id:inv@example.com"})
	var shown []Message
	if failed || json.Unmarshal([]byte(out), &shown) != nil || len(shown) != 1 {
		t.Fatalf("show = %s", out)
	}
	m := shown[0]
	if m.Subject != "Invoice" || strings.TrimSpace(m.Body) != "hello there" || len(m.Attachments) != 1 || m.Attachments[0].Part != 5 {
		t.Errorf("message = %+v", m)
	}
	out, _ = call(t, cs, "notmuch_show", map[string]any{"query": "id:inv@example.com", "include_html": true})
	if !strings.Contains(out, "rendered HTML") || !strings.Contains(out, "hello **there**") || strings.Contains(out, "<b>") {
		t.Errorf("show with html = %s", out)
	}

	out, failed = call(t, cs, "notmuch_extract", map[string]any{"message_id": "inv@example.com", "part": 5})
	if failed || !strings.HasPrefix(out, "wrote 3 bytes to ") {
		t.Fatalf("extract = %s", out)
	}
	path := strings.TrimPrefix(out, "wrote 3 bytes to ")
	if filepath.Base(path) != "escape.pdf" || !strings.HasPrefix(path, os.Getenv("EMAIL_ENGINE_ATTACHMENT_DIR")) {
		t.Errorf("extracted to %s", path)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "PDF" { //nolint:gosec
		t.Errorf("extracted %q %v", data, err)
	}

	if out, _ := call(t, cs, "notmuch_count", map[string]any{"query": "*", "output": "threads"}); out != "2" {
		t.Errorf("count = %s", out)
	}
	if out, failed := call(t, cs, "notmuch_tag", map[string]any{"query": "id:inv@example.com", "add": []string{"paid"}, "remove": []string{"inbox"}}); failed || !strings.HasPrefix(out, "tagged 1 messages") {
		t.Errorf("tag = %s", out)
	}
	if out, _ := call(t, cs, "notmuch_tags", map[string]any{"query": "id:inv@example.com"}); !strings.Contains(out, `"paid"`) || strings.Contains(out, `"inbox"`) {
		t.Errorf("tags = %s", out)
	}
}

func TestToolsRejectBadInput(t *testing.T) {
	cs := session(t)
	for name, args := range map[string]map[string]any{
		"notmuch_search":  {"query": " "},
		"notmuch_tag":     {"query": "*", "add": []string{"-flag"}},
		"notmuch_extract": {"message_id": "inv@example.com", "part": 0},
		"notmuch_count":   {"query": "*", "output": "bytes"},
	} {
		if out, failed := call(t, cs, name, args); !failed {
			t.Errorf("%s accepted %v: %s", name, args, out)
		}
	}
}

func TestSafeName(t *testing.T) {
	cases := map[string]string{
		"invoice.pdf":                "invoice.pdf",
		"../../.ssh/authorized_keys": "authorized_keys",
		`..\..\windows\system32`:     "system32",
		"":                           "part-3",
		"..":                         "part-3",
		".bashrc":                    "part-3.bashrc",
		"with\nnewline.txt":          "with_newline.txt",
	}
	for in, want := range cases {
		if got := safeName(in, 3); got != want {
			t.Errorf("safeName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestTruncateKeepsRunesWhole(t *testing.T) {
	got := truncate("æøå", 3)
	if !strings.HasPrefix(got, "æ\n") {
		t.Errorf("truncate = %q", got)
	}
}
