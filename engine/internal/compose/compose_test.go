package compose

import (
	"net/mail"
	"strings"
	"testing"
	"time"

	"github.com/stubbedev/email.nvim/engine/internal/message"
)

var at = time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)

func addr(t *testing.T, s string) *mail.Address {
	t.Helper()
	a, err := mail.ParseAddress(s)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func TestSingleTextPartWithoutAttachments(t *testing.T) {
	m := &Message{From: addr(t, "Me <me@x.y>"), To: []*mail.Address{addr(t, "you@x.y")}, Subject: "Hi", Body: "hello", Date: at, MessageID: "1.a@x.y"}
	out, err := m.Bytes(true)
	if err != nil {
		t.Fatal(err)
	}
	want := "Date: Thu, 19 Nov 2026 12:00:00 +0000\nFrom: Me <me@x.y>\nTo: you@x.y\nSubject: Hi\nMessage-ID: <1.a@x.y>\nMIME-Version: 1.0\n" +
		"Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 7bit\n\nhello\n"
	if string(out) != want {
		t.Errorf("got\n%s\nwant\n%s", out, want)
	}
}

func TestBccOnlyInTheStoredCopy(t *testing.T) {
	m := &Message{From: addr(t, "me@x.y"), Bcc: []*mail.Address{addr(t, "hidden@x.y")}, Body: "x", Date: at, MessageID: "1@x.y"}
	stored, _ := m.Bytes(true)
	wire, _ := m.Bytes(false)
	if !strings.Contains(string(stored), "Bcc: hidden@x.y") || strings.Contains(string(wire), "hidden@x.y") {
		t.Errorf("stored:\n%s\nwire:\n%s", stored, wire)
	}
	if got := m.Recipients(); len(got) != 1 || got[0] != "hidden@x.y" {
		t.Errorf("recipients = %v", got)
	}
}

func TestAttachmentsHTMLAndCalendarRoundTrip(t *testing.T) {
	m := &Message{
		From: addr(t, "me@x.y"), To: []*mail.Address{{Name: "Søren", Address: "s@x.y"}}, Subject: "Fil æ",
		Body: "se **vedhæftet**", HTML: true, Calendar: &Calendar{ICS: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", Method: "REPLY"},
		Attachments: []Attachment{{Filename: "rapport ø.pdf", Data: []byte("PDFDATA")}}, Date: at, MessageID: "1@x.y",
	}
	out, err := m.Bytes(true)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := message.Parse(out)
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if parsed.Get("Subject") != "Fil æ" || parsed.Get("To") != "Søren <s@x.y>" {
		t.Errorf("headers: subject %q to %q", parsed.Get("Subject"), parsed.Get("To"))
	}
	types := []string{}
	parsed.Root.Walk(func(p *message.Part) { types = append(types, p.ContentType) })
	if strings.Join(types, ",") != "multipart/mixed,multipart/alternative,text/plain,text/html,text/calendar,application/pdf" {
		t.Errorf("structure = %v", types)
	}
	if got := parsed.Find(3).Text(); got != "se **vedhæftet**\n" {
		t.Errorf("plain = %q", got)
	}
	if got := parsed.Find(4).Text(); !strings.Contains(got, "<strong>vedhæftet</strong>") {
		t.Errorf("html = %q", got)
	}
	if p := parsed.Find(5); p.Params["method"] != "REPLY" || !strings.Contains(p.Text(), "BEGIN:VCALENDAR") {
		t.Errorf("calendar = %+v", p)
	}
	if p := parsed.Find(6); p.Filename != "rapport ø.pdf" || string(p.Body) != "PDFDATA" {
		t.Errorf("attachment = %+v", p)
	}
}

func TestLongLinesAreQuotedPrintable(t *testing.T) {
	m := &Message{From: addr(t, "me@x.y"), Body: strings.Repeat("a", 1200), Date: at, MessageID: "1@x.y"}
	out, _ := m.Bytes(true)
	for line := range strings.SplitSeq(string(out), "\n") {
		if len(line) > 76 && !strings.HasPrefix(line, "Content-") {
			t.Fatalf("line of %d bytes", len(line))
		}
	}
	parsed, _ := message.Parse(out)
	if parsed.Root.Text() != strings.Repeat("a", 1200)+"\n" {
		t.Error("body did not round-trip")
	}
}

type me []string

func (m me) Owns(address string) bool {
	for _, a := range m {
		if strings.EqualFold(a, address) {
			return true
		}
	}
	return false
}

func original(t *testing.T, headers ...string) *message.Message {
	t.Helper()
	m, err := message.Parse([]byte(strings.Join(headers, "\n") + "\n\nbody\n"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestReplyToSenderUsesReplyToUnlessAListMungedIt(t *testing.T) {
	m := original(t, "From: Ann <ann@x.y>", "To: Me@x.y, bob@x.y", "Cc: cid@x.y", "Reply-To: ann-alt@x.y", "Subject: Plans", "Message-ID: <p@x.y>", "References: <a@x.y>")
	r := BuildReply(m, me{"me@x.y"}, false)
	if DisplayList(r.To) != "ann-alt@x.y" || len(r.Cc) != 0 || r.Subject != "Re: Plans" || r.InReplyTo != "<p@x.y>" || r.References != "<a@x.y> <p@x.y>" || r.Recipient != "Me@x.y" {
		t.Errorf("reply = %+v", r)
	}
	munged := original(t, "From: Ann <ann@x.y>", "To: list@x.y", "Reply-To: list@x.y", "Subject: Re: Plans")
	if r := BuildReply(munged, me{"me@x.y"}, false); DisplayList(r.To) != "Ann <ann@x.y>" || r.Subject != "Re: Plans" {
		t.Errorf("munged reply = %+v", r)
	}
}

func TestReplyAllDropsMeAndDuplicates(t *testing.T) {
	m := original(t, "From: Ann <ann@x.y>", "To: me@x.y, bob@x.y, ann@x.y", "Cc: cid@x.y, ME@x.y")
	r := BuildReply(m, me{"me@x.y"}, true)
	if DisplayList(r.To) != "Ann <ann@x.y>, bob@x.y" || DisplayList(r.Cc) != "cid@x.y" {
		t.Errorf("reply = to %q cc %q", DisplayList(r.To), DisplayList(r.Cc))
	}
}

func TestReplyToMyOwnMessageGoesToItsRecipients(t *testing.T) {
	m := original(t, "From: Me <me@x.y>", "To: bob@x.y", "Cc: cid@x.y")
	r := BuildReply(m, me{"me@x.y"}, true)
	if DisplayList(r.To) != "bob@x.y" || DisplayList(r.Cc) != "cid@x.y" {
		t.Errorf("reply = to %q cc %q", DisplayList(r.To), DisplayList(r.Cc))
	}
}

func TestDisplayQuotesSpecialsButKeepsUTF8(t *testing.T) {
	if got := Display(&mail.Address{Name: "Søren", Address: "s@x.y"}); got != "Søren <s@x.y>" {
		t.Error(got)
	}
	if got := Display(&mail.Address{Name: "Doe, Jane", Address: "j@x.y"}); got != `"Doe, Jane" <j@x.y>` {
		t.Error(got)
	}
}
