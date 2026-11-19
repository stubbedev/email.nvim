package message

import (
	"strings"
	"testing"
)

func lf(lines ...string) []byte { return []byte(strings.Join(lines, "\r\n")) }

func TestParseNumbersPartsDepthFirstAndDecodes(t *testing.T) {
	raw := lf(
		"From: =?ISO-8859-1?Q?S=F8ren?= <s@x.y>",
		"Subject: =?UTF-8?B?w6bDuMOl?= ok",
		`Content-Type: multipart/mixed; boundary="m"`,
		"",
		"--m",
		`Content-Type: multipart/alternative; boundary="a"`,
		"",
		"--a",
		"Content-Type: text/plain; charset=iso-8859-1",
		"Content-Transfer-Encoding: quoted-printable",
		"",
		"caf=E9 =",
		"au lait",
		"--a",
		"Content-Type: text/html; charset=utf-8",
		"Content-Transfer-Encoding: base64",
		"",
		"PHA+aGk8L3A+",
		"--a--",
		"--m",
		"Content-Type: application/pdf",
		"Content-Disposition: attachment; filename*=UTF-8''rapport%20%C3%B8.pdf",
		"Content-Transfer-Encoding: base64",
		"",
		"UERG",
		"--m",
		"Content-Type: message/rfc822",
		"",
		"Subject: inner",
		"",
		"inner body",
		"--m--",
		"",
	)
	m, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.Get("From"); got != "Søren <s@x.y>" {
		t.Errorf("From = %q", got)
	}
	if got := m.Get("Subject"); got != "æøå ok" {
		t.Errorf("Subject = %q", got)
	}
	want := map[int]string{1: "multipart/mixed", 2: "multipart/alternative", 3: "text/plain", 4: "text/html", 5: "application/pdf", 6: "message/rfc822", 7: "text/plain"}
	for id, ct := range want {
		p := m.Find(id)
		if p == nil || p.ContentType != ct {
			t.Fatalf("part %d = %+v, want %s", id, p, ct)
		}
	}
	if got := m.Find(3).Text(); got != "café au lait" {
		t.Errorf("quoted-printable latin-1 text = %q", got)
	}
	if got := m.Find(4).Text(); got != "<p>hi</p>" {
		t.Errorf("base64 html = %q", got)
	}
	if p := m.Find(5); p.Filename != "rapport ø.pdf" || string(p.Body) != "PDF" || p.Disposition != "attachment" {
		t.Errorf("attachment = %+v", p)
	}
	if p := m.Find(6); p.Embedded == nil || p.Embedded.Get("Subject") != "inner" {
		t.Errorf("embedded message = %+v", p)
	}
}

func TestParseToleratesAMissingFinalBoundary(t *testing.T) {
	m, err := Parse(lf(`Content-Type: multipart/mixed; boundary="b"`, "", "--b", "Content-Type: text/plain", "", "cut off"))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Root.Children) != 1 || m.Root.Children[0].Text() != "cut off" {
		t.Errorf("children = %+v", m.Root.Children)
	}
}

func TestInvalidContentTypeIsPlainText(t *testing.T) {
	m, err := Parse(lf("Content-Type: ;;;", "", "body"))
	if err != nil {
		t.Fatal(err)
	}
	if m.Root.ContentType != "text/plain" || m.Root.Text() != "body" {
		t.Errorf("root = %+v", m.Root)
	}
}

func TestInvalidUTF8IsReplaced(t *testing.T) {
	m, err := Parse([]byte("Content-Type: text/plain; charset=utf-8\n\nbad \xff byte"))
	if err != nil {
		t.Fatal(err)
	}
	if got := m.Root.Text(); got != "bad � byte" {
		t.Errorf("text = %q", got)
	}
}

func TestParseAddressesDecodesWordsAndKeepsCommasInQuotes(t *testing.T) {
	got := ParseAddresses(`"Doe, Jane" <jane@x.y>, =?UTF-8?Q?S=C3=B8ren?= <s@x.y>, bob@x.y`)
	if len(got) != 3 || got[0].Name != "Doe, Jane" || got[1].Name != "Søren" || got[2].Address != "bob@x.y" {
		t.Errorf("addresses = %+v", got)
	}
}
