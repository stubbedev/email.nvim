package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/stubbedev/email.nvim/engine"
)

func exec(t *testing.T, stdin string, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := run(args, strings.NewReader(stdin), &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestCommands(t *testing.T) {
	if code, out, _ := exec(t, "", "version"); code != 0 || out != "email-engine "+engine.Version()+"\n" {
		t.Errorf("version = %d %q", code, out)
	}
	if code, _, errOut := exec(t, "", "nope"); code != 2 || !strings.Contains(errOut, `unknown command "nope"`) {
		t.Errorf("unknown = %d %q", code, errOut)
	}
	if code, _, _ := exec(t, ""); code != 2 {
		t.Errorf("no command = %d", code)
	}
}

func TestConvert(t *testing.T) {
	cases := []struct {
		stdin string
		args  []string
		want  string
	}{
		{"<p>Hi <b>x</b></p>", []string{"--html"}, "Hi **x**"},
		{"<p>Hi</p><img src=\"cid:a\" alt=\"A\">", []string{"--html", "--images"}, "Hi\n\n![A](cid:a)"},
		{"one \ntwo\n", []string{"--plain", "--flowed"}, "one two"},
		{"one \ntwo\n", []string{"--plain"}, "one \ntwo\n"},
		{"**b**\nnext\n", []string{"--to-html"}, "<p><strong>b</strong><br>\nnext</p>\n"},
		{"BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Sync\nEND:VEVENT\nEND:VCALENDAR\n", nil, "# Sync"},
	}
	for _, c := range cases {
		code, out, errOut := exec(t, c.stdin, append([]string{"convert"}, c.args...)...)
		if code != 0 || out != c.want {
			t.Errorf("convert %v = %d %q (stderr %q), want %q", c.args, code, out, errOut, c.want)
		}
	}
	if code, _, errOut := exec(t, "x", "convert", "--to-html", "--images"); code != 2 || !strings.Contains(errOut, "takes no other flags") {
		t.Errorf("--to-html --images = %d %q", code, errOut)
	}
}
