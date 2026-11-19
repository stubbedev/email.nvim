package view

import (
	"strings"
	"testing"

	"github.com/stubbedev/email.nvim/engine/internal/message"
)

func parse(t *testing.T, lines ...string) *message.Message {
	t.Helper()
	m, err := message.Parse([]byte(strings.Join(lines, "\n")))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

var htmlFirst = Options{Alternatives: []string{"text/html", "text/plain"}, Raw: map[string]bool{}}

func TestAlternativePicksThePreferredTypeAndRendersIt(t *testing.T) {
	v := Build(parse(t,
		`Content-Type: multipart/alternative; boundary="b"`, "",
		"--b", "Content-Type: text/plain", "", "plain",
		"--b", "Content-Type: text/html", "", "<p>Hi <b>there</b></p>",
		"--b--",
	), htmlFirst)
	if len(v.Blocks) != 1 || v.Blocks[0].ContentType != "text/html" || v.Blocks[0].Content != "Hi **there**" {
		t.Errorf("blocks = %+v", v.Blocks)
	}
}

func TestRawTypesAreLeftForTheClientToRender(t *testing.T) {
	opts := htmlFirst
	opts.Raw = map[string]bool{"text/html": true}
	v := Build(parse(t, "Content-Type: text/html", "", "<p>x</p>"), opts)
	if v.Blocks[0].Content != "<p>x</p>" {
		t.Errorf("content = %q", v.Blocks[0].Content)
	}
}

func TestRelatedCountsAsItsRootTypeAndListsNamedParts(t *testing.T) {
	v := Build(parse(t,
		`Content-Type: multipart/alternative; boundary="a"`, "",
		"--a", "Content-Type: text/plain", "", "plain",
		"--a", `Content-Type: multipart/related; boundary="r"`, "",
		"--r", "Content-Type: text/html", "", "<b>x</b>",
		"--r", "Content-Type: image/png; name=logo.png", "Content-ID: <logo@x>", "", "PNG",
		"--r", "Content-Type: image/png", "", "PNG",
		"--r--", "--a--",
	), htmlFirst)
	if v.Blocks[0].ContentType != "text/html" {
		t.Errorf("blocks = %+v", v.Blocks)
	}
	if len(v.Attachments) != 1 || v.Attachments[0].Filename != "logo.png" || v.Attachments[0].Part != 5 {
		t.Errorf("attachments = %+v", v.Attachments)
	}
	if len(v.Images) != 2 || v.Images[0].ContentID != "logo@x" || !v.Images[0].Attachment || v.Images[1].Attachment {
		t.Errorf("images = %+v", v.Images)
	}
}

func TestSignedShowsTheSignedContent(t *testing.T) {
	v := Build(parse(t,
		`Content-Type: multipart/signed; boundary="s"`, "",
		"--s", "Content-Type: text/plain", "", "signed text",
		"--s", "Content-Type: application/pkcs7-signature; name=smime.p7s", "", "SIG",
		"--s--",
	), htmlFirst)
	if len(v.Blocks) != 1 || v.Blocks[0].Content != "signed text" || len(v.Attachments) != 0 {
		t.Errorf("view = %+v", v)
	}
}

func TestAttachedMessagesRenderHeadersAndBodyInline(t *testing.T) {
	v := Build(parse(t, "Content-Type: message/rfc822", "", "From: a@b.c", "Subject: inner", "", "inner body"), htmlFirst)
	if len(v.Blocks) != 2 || v.Blocks[0].Kind != HeadersBlock || v.Blocks[0].Headers["Subject"] != "inner" || v.Blocks[1].Content != "inner body" {
		t.Errorf("blocks = %+v", v.Blocks)
	}
}

func TestTextWithAttachmentDispositionIsAnAttachment(t *testing.T) {
	v := Build(parse(t, "Content-Type: text/csv", "Content-Disposition: attachment; filename=a.csv", "", "1,2"), htmlFirst)
	if len(v.Blocks) != 0 || len(v.Attachments) != 1 || v.Attachments[0].Filename != "a.csv" || v.Attachments[0].Size != 3 {
		t.Errorf("view = %+v", v)
	}
}

func TestCalendarsAreInlineAndFlowedTextIsDewrapped(t *testing.T) {
	v := Build(parse(t,
		`Content-Type: multipart/mixed; boundary="m"`, "",
		"--m", "Content-Type: text/plain; format=flowed", "", "one ", "two",
		"--m", "Content-Type: text/calendar; method=REQUEST", "", "BEGIN:VCALENDAR", "END:VCALENDAR",
		"--m--",
	), htmlFirst)
	if v.Blocks[0].Content != "one two" {
		t.Errorf("flowed = %q", v.Blocks[0].Content)
	}
	if len(v.Calendars) != 1 || !strings.Contains(v.Calendars[0].Content, "BEGIN:VCALENDAR") {
		t.Errorf("calendars = %+v", v.Calendars)
	}
}
