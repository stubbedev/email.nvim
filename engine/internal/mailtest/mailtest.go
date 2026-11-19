package mailtest

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var Folders = []string{"INBOX", "Sent", "Drafts", "Archive", "Trash"}

type Mail struct {
	Root string
}

func Setup(t *testing.T, messages map[string]string) *Mail {
	t.Helper()
	if _, err := exec.LookPath("notmuch"); err != nil {
		t.Skip("notmuch is not installed")
	}
	dir := t.TempDir()
	root := filepath.Join(dir, "mail")
	for _, folder := range Folders {
		for _, sub := range []string{"cur", "new", "tmp"} {
			if err := os.MkdirAll(filepath.Join(root, "acct", folder, sub), 0o700); err != nil {
				t.Fatal(err)
			}
		}
	}
	config := filepath.Join(dir, "notmuch-config")
	content := fmt.Sprintf("[database]\npath=%s\n[user]\nname=Test User\nprimary_email=me@example.com\n[new]\ntags=unread;inbox\n[search]\nexclude_tags=deleted;spam\n[maildir]\nsynchronize_flags=true\n", root)
	if err := os.WriteFile(config, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOTMUCH_CONFIG", config)
	m := &Mail{Root: root}
	for name, body := range messages {
		m.Write(t, name, body)
	}
	m.Index(t)
	return m
}

func (m *Mail) Write(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(m.Root, "acct", filepath.FromSlash(name))
	if err := os.WriteFile(path, []byte(strings.TrimLeft(body, "\n")), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func (m *Mail) Index(t *testing.T) {
	t.Helper()
	if out, err := exec.Command("notmuch", "new", "--quiet").CombinedOutput(); err != nil {
		t.Fatalf("notmuch new: %v: %s", err, out)
	}
}

func Message(id, from, to, subject, date, body string, extra ...string) string {
	headers := []string{"From: " + from, "To: " + to, "Subject: " + subject, "Message-ID: <" + id + ">", "Date: " + date}
	headers = append(headers, extra...)
	return strings.Join(headers, "\n") + "\nContent-Type: text/plain; charset=utf-8\n\n" + body + "\n"
}
