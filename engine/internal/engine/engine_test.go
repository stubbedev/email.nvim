package engine

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stubbedev/email.nvim/engine/internal/doc"
	"github.com/stubbedev/email.nvim/engine/internal/mailtest"
	"github.com/stubbedev/email.nvim/engine/internal/message"
	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
	"github.com/stubbedev/email.nvim/engine/internal/smtp"
	"github.com/stubbedev/email.nvim/engine/internal/smtp/smtptest"
)

const (
	ann = "Ann <ann@example.org>"
	me  = "Test User <me@example.com>"
)

func fixture(t *testing.T) (*mailtest.Mail, *Engine) {
	t.Helper()
	mail := mailtest.Setup(t, map[string]string{
		"INBOX/new/1001.x,U=1": mailtest.Message("p1@example.org", ann, "me@example.com, bob@example.org", "Plans", "Thu, 19 Nov 2026 10:01:00 +0000", "first"),
		"INBOX/new/1002.x,U=2": mailtest.Message("p2@example.org", "Bob <bob@example.org>", "me@example.com", "Re: Plans", "Thu, 19 Nov 2026 10:02:00 +0000", "second", "In-Reply-To: <p1@example.org>", "References: <p1@example.org>"),
		"INBOX/new/1003.x,U=3": mailtest.Message("news@example.org", "News <news@example.org>", "me@example.com", "Weekly", "Thu, 19 Nov 2026 10:03:00 +0000", "<p>hi</p>"),
		"Sent/cur/1004.x:2,S":  mailtest.Message("s1@example.com", me, "Ann <ann@example.org>", "Hello Ann", "Thu, 19 Nov 2026 09:00:00 +0000", "hi ann"),
	})
	e, err := New(Config{
		Accounts: []AccountConfig{{
			Name: "Acct", Maildir: "acct", From: me, Addresses: []string{"me@example.com"},
			Inbox: "INBOX", Sent: "Sent", Drafts: "Drafts", Archive: "Archive", Trash: "Trash",
		}},
		HTMLAlternative: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	return mail, e
}

func TestThreadsCountsAndConversations(t *testing.T) {
	_, e := fixture(t)
	page, err := e.Threads("folder:acct/INBOX", 0, 0, 10, true)
	if err != nil {
		t.Fatal(err)
	}
	if page.Total == nil || *page.Total != 2 || len(page.Threads) != 2 {
		t.Fatalf("page = %+v", page)
	}
	plans := page.Threads[1]
	if plans.Subject != "Plans" || plans.Total != 2 || plans.Authors != "Ann, Bob" || len(plans.MessageIDs) != 2 || !slices.Contains(plans.Tags, "unread") {
		t.Errorf("thread = %+v", plans)
	}
	more, err := e.Threads("folder:acct/INBOX", 0, 1, 10, false)
	if err != nil || more.Total != nil || len(more.Threads) != 1 || more.Threads[0].ID != plans.ID {
		t.Errorf("second page = %+v %v", more, err)
	}
	counts, err := e.Counts([]string{"tag:inbox and tag:unread", "tag:sent"})
	if err != nil || !slices.Equal(counts, []int{3, 0}) {
		t.Errorf("counts = %v %v", counts, err)
	}
	newest, err := e.NewestMessage(plans.ID, "tag:inbox")
	if err != nil || newest != "p2@example.org" {
		t.Errorf("newest = %q %v", newest, err)
	}
	conversation, err := e.Thread(plans.ID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(conversation) != 2 || conversation[0].ID != "p1@example.org" || strings.TrimSpace(conversation[1].Blocks[0].Content) != "second" || !slices.Equal(conversation[0].Accounts, []int{1}) {
		t.Errorf("conversation = %+v", conversation)
	}
}

func TestTagSyncsMaildirFlagsAndBumpsTheRevision(t *testing.T) {
	_, e := fixture(t)
	before, err := e.Revision()
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Tag([]string{"p1@example.org"}, []string{"-unread", "+flagged"}); err != nil {
		t.Fatal(err)
	}
	m, err := e.Message("p1@example.org", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if slices.Contains(m.Tags, "unread") || !slices.Contains(m.Tags, "flagged") || !strings.HasSuffix(m.Files[0], ":2,FS") {
		t.Errorf("message = %+v", m)
	}
	if after, _ := e.Revision(); after == before {
		t.Error("revision did not change")
	}
	if err := e.Tag([]string{"p1@example.org"}, []string{"flagged"}); err == nil {
		t.Error("a change without + or - must be rejected")
	}
}

func TestArchiveDeleteAndUndo(t *testing.T) {
	_, e := fixture(t)
	undo, err := e.Relocate([]string{"p1@example.org"}, Archive, "", t.TempDir(), 0)
	if err != nil {
		t.Fatal(err)
	}
	m, _ := e.Message("p1@example.org", nil, nil)
	if len(m.Files) != 1 || !strings.Contains(m.Files[0], filepath.Join("acct", "Archive", "cur")) || slices.Contains(m.Tags, "inbox") {
		t.Fatalf("archived = %+v", m)
	}
	if err := e.Undo(undo); err != nil {
		t.Fatal(err)
	}
	m, _ = e.Message("p1@example.org", nil, nil)
	if len(m.Files) != 1 || !strings.Contains(m.Files[0], filepath.Join("acct", "INBOX", "cur")) || !slices.Contains(m.Tags, "inbox") {
		t.Fatalf("restored = %+v", m)
	}

	permanent, err := e.PermanentDelete([]string{"news@example.org"}, 0)
	if err != nil || permanent {
		t.Fatalf("first delete permanent = %v %v", permanent, err)
	}
	if _, err := e.Relocate([]string{"news@example.org"}, Delete, "", t.TempDir(), 0); err != nil {
		t.Fatal(err)
	}
	if permanent, _ := e.PermanentDelete([]string{"news@example.org"}, 0); !permanent {
		t.Fatal("a message in the trash must be deleted for good")
	}
	undo, err = e.Relocate([]string{"news@example.org"}, Delete, "", t.TempDir(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.Message("news@example.org", nil, nil); err == nil {
		t.Fatal("the deleted message is still indexed")
	}
	if err := e.Undo(undo); err != nil {
		t.Fatal(err)
	}
	if m, err := e.Message("news@example.org", nil, nil); err != nil || !strings.Contains(m.Files[0], filepath.Join("acct", "Trash")) {
		t.Errorf("undeleted = %+v %v", m, err)
	}

	folders, err := e.Folders([]string{"p1@example.org"}, 0)
	if err != nil || !slices.Equal(folders, []string{"Archive", "Drafts", "INBOX", "Sent", "Trash"}) {
		t.Errorf("folders = %v %v", folders, err)
	}
	if _, err := e.Relocate([]string{"p2@example.org"}, Move, "Archive", t.TempDir(), 0); err != nil {
		t.Fatal(err)
	}
}

func TestFailedRelocateRollsBack(t *testing.T) {
	mail, e := fixture(t)
	if err := os.RemoveAll(filepath.Join(mail.Root, "acct", "Archive", "cur")); err != nil {
		t.Fatal(err)
	}
	_, err := e.Relocate([]string{"p1@example.org", "p2@example.org"}, Archive, "", t.TempDir(), 0)
	if err == nil {
		t.Fatal("expected the move into a broken folder to fail")
	}
	m, _ := e.Message("p1@example.org", nil, nil)
	if !strings.Contains(m.Files[0], filepath.Join("acct", "INBOX")) || !slices.Contains(m.Tags, "inbox") {
		t.Errorf("not rolled back: %+v", m)
	}
}

func TestReplyAndAddresses(t *testing.T) {
	_, e := fixture(t)
	r, err := e.Reply("p1@example.org", true, 0)
	if err != nil {
		t.Fatal(err)
	}
	if r.From != me || r.To != "Ann <ann@example.org>, bob@example.org" || r.Subject != "Re: Plans" || r.InReplyTo != "<p1@example.org>" || r.Account != 1 || r.Address != "me@example.com" {
		t.Errorf("reply = %+v", r)
	}
	ranked, err := e.Addresses()
	if err != nil {
		t.Fatal(err)
	}
	if len(ranked) < 2 || ranked[0].Address != "ann@example.org" || ranked[0].Name != "Ann" || ranked[0].Score != 11 {
		t.Errorf("ranked = %+v", ranked)
	}
}

func TestDraftsAndSending(t *testing.T) {
	_, e := fixture(t)
	draft := Draft{From: me, To: "Ann <ann@example.org>", Bcc: "hidden@example.org", Subject: "Lunch", Body: "**Friday**?", Replying: "p1@example.org"}
	id, err := e.SaveDraft(draft)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := e.Message(id, nil, nil)
	if err != nil || !slices.Contains(saved.Tags, "draft") || slices.Contains(saved.Tags, "unread") || !strings.Contains(saved.Files[0], filepath.Join("acct", "Drafts", "cur")) {
		t.Fatalf("draft = %+v %v", saved, err)
	}

	fake := smtptest.Start(t, "LOGIN")
	e.accounts[0].SMTP = &SMTPConfig{Host: "127.0.0.1", Port: fake.Port, Security: smtp.None, User: "me", PasswordCmd: []string{"printf", "secret\n"}}
	draft.DraftID = id
	if err := e.Send(t.Context(), draft); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(fake.Log(), "LOGIN me secret") || !strings.Contains(fake.Log(), "RCPT TO:<hidden@example.org>") {
		t.Errorf("smtp session:\n%s", fake.Log())
	}
	wire := fake.Messages()
	if len(wire) != 1 || strings.Contains(wire[0], "hidden@example.org") || !strings.Contains(wire[0], "text/html") {
		t.Errorf("wire message:\n%v", wire)
	}
	if _, err := e.Message(id, nil, nil); err == nil {
		t.Error("the draft survived sending")
	}
	if counts, _ := e.Counts([]string{"tag:sent and subject:Lunch", "tag:replied and id:p1@example.org", "tag:draft"}); !slices.Equal(counts, []int{1, 1, 0}) {
		t.Errorf("counts after send = %v", counts)
	}
	page, _ := e.Threads("tag:sent and subject:Lunch", 0, 0, 1, false)
	sent, err := e.Message(page.Threads[0].MessageIDs[0], nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if sent.Headers["Bcc"] != "hidden@example.org" {
		t.Errorf("the Sent copy lost its Bcc: %+v", sent.Headers)
	}
	raw, _ := os.ReadFile(sent.Files[0])
	if parsed, err := message.Parse(raw); err != nil || parsed.Get("In-Reply-To") != "" {
		t.Errorf("parsed sent copy: %v", err)
	}

	if err := e.Send(t.Context(), Draft{From: me, Body: "x"}); err == nil || !strings.Contains(err.Error(), "no recipients") {
		t.Errorf("send without recipients: %v", err)
	}
	if err := e.Send(t.Context(), Draft{From: "stranger@example.net", To: "a@b.c"}); err == nil || !strings.Contains(err.Error(), "belongs to no configured account") {
		t.Errorf("send from a stranger: %v", err)
	}
}

func TestExtract(t *testing.T) {
	mail, e := fixture(t)
	mail.Write(t, "INBOX/new/1005.x", strings.Join([]string{
		"From: " + ann, "To: me@example.com", "Subject: File", "Message-ID: <f@example.org>",
		`Content-Type: multipart/mixed; boundary="b"`, "",
		"--b", "Content-Type: text/plain", "", "see attached",
		"--b", "Content-Type: application/pdf", "Content-Disposition: attachment; filename=a.pdf", "Content-Transfer-Encoding: base64", "", "UERG",
		"--b--", "",
	}, "\n"))
	mail.Index(t)
	m, err := e.Message("f@example.org", nil, nil)
	if err != nil || len(m.Attachments) != 1 || m.Attachments[0].Part != 3 {
		t.Fatalf("message = %+v %v", m, err)
	}
	path := filepath.Join(t.TempDir(), "a.pdf")
	n, err := e.Extract("f@example.org", 3, path)
	if data, _ := os.ReadFile(path); err != nil || n != 3 || string(data) != "PDF" { //nolint:gosec
		t.Errorf("extract = %d %v %q", n, err, data)
	}
	if _, err := e.Extract("f@example.org", 1, path); err == nil {
		t.Error("extracting a multipart container must fail")
	}
}

func TestCalendarReply(t *testing.T) {
	mail, e := fixture(t)
	mail.Write(t, "INBOX/new/1006.x", strings.Join([]string{
		"From: Organizer <org@example.org>", "To: me@example.com", "Subject: Invitation: Team sync", "Message-ID: <inv@example.org>",
		`Content-Type: multipart/alternative; boundary="b"`, "",
		"--b", "Content-Type: text/html; charset=utf-8", "", "<p>Join us</p>",
		"--b", "Content-Type: text/calendar; charset=utf-8; method=REQUEST", "",
		"BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT", "UID:abc-123", "SUMMARY:Team sync",
		"ORGANIZER;CN=Organizer:mailto:org@example.org",
		"ATTENDEE;CN=Test User;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com",
		"END:VEVENT", "END:VCALENDAR",
		"--b--", "",
	}, "\n"))
	mail.Index(t)
	m, err := e.Message("inv@example.org", nil, nil)
	if err != nil || len(m.Calendars) != 1 || m.Calendars[0].Method != "REQUEST" || m.Calendars[0].Summary != "Team sync" {
		t.Fatalf("calendars = %+v %v", m.Calendars, err)
	}
	draft, err := e.CalendarReply("inv@example.org", "TENTATIVE", 0)
	if err != nil {
		t.Fatal(err)
	}
	if draft.To != "Organizer <org@example.org>" || draft.Subject != "Tentative: Team sync" || draft.Body != "Test User has tentatively accepted the invitation." || draft.Replying != "inv@example.org" {
		t.Errorf("draft = %+v", draft)
	}
	if !strings.Contains(draft.ICS, "PARTSTAT=TENTATIVE:mailto:me@example.com") {
		t.Errorf("ics = %s", draft.ICS)
	}
	if _, err := e.CalendarReply("p1@example.org", "ACCEPTED", 0); err == nil {
		t.Error("a message without an invite must be rejected")
	}
}

func TestPagingCachingAndPrefetch(t *testing.T) {
	mail, e := fixture(t)
	for i := range 7 {
		mail.Write(t, fmt.Sprintf("INBOX/new/20%02d.x", i), mailtest.Message(fmt.Sprintf("bulk%d@example.org", i), ann, "me@example.com", fmt.Sprintf("Bulk %d", i), fmt.Sprintf("Fri, 20 Nov 2026 10:%02d:00 +0000", i), "x"))
	}
	mail.Index(t)
	const q = "folder:acct/INBOX"
	var paged []string
	for offset := 0; ; offset += 3 {
		page, err := e.Threads(q, notmuch.NewestFirst, offset, 3, false)
		if err != nil {
			t.Fatal(err)
		}
		for _, th := range page.Threads {
			paged = append(paged, th.ID)
		}
		if len(page.Threads) < 3 {
			break
		}
	}
	whole, err := e.Threads(q, notmuch.NewestFirst, 0, 100, true)
	if err != nil {
		t.Fatal(err)
	}
	var all []string
	for _, th := range whole.Threads {
		all = append(all, th.ID)
	}
	if !slices.Equal(paged, all) || *whole.Total != len(all) {
		t.Fatalf("cursor pages %v, one page %v (total %d)", paged, all, *whole.Total)
	}

	if err := e.Tag([]string{"bulk0@example.org"}, []string{"-inbox"}); err != nil {
		t.Fatal(err)
	}
	if n, _ := e.CountThreads("tag:inbox and folder:acct/INBOX"); n != len(all)-1 {
		t.Errorf("count after a write = %d, want %d (stale cache)", n, len(all)-1)
	}
	page, _ := e.Threads(q, notmuch.NewestFirst, 0, 100, false)
	if !slices.ContainsFunc(page.Threads, func(th ThreadSummary) bool {
		return slices.Contains(th.MessageIDs, "bulk0@example.org") && !slices.Contains(th.Tags, "inbox")
	}) {
		t.Errorf("first page after a write still shows old tags")
	}

	<-e.Prefetch([]string{"folder:acct/Sent"}, 50)
	revision, _ := e.Revision()
	if _, ok := e.cache.get(pageKey("folder:acct/Sent", notmuch.NewestFirst, 50), revision); !ok {
		t.Error("prefetch did not cache the first page")
	}
	if _, ok := e.cache.get(countKey("folder:acct/Sent"), revision); !ok {
		t.Error("prefetch did not cache the count")
	}
}

func TestRenderedDocsAndTheViewCache(t *testing.T) {
	_, e := fixture(t)
	e.markdown = doc.Options{Headings: []string{"# "}, Bullets: []string{"*"}, Quote: "|", Link: "L ", Email: "E ", Image: "I ", Types: []string{"text/html", "text/plain"}}
	r := &Render{Width: 40}
	page, err := e.Threads("folder:acct/INBOX", notmuch.NewestFirst, 0, 10, false)
	if err != nil {
		t.Fatal(err)
	}
	i := slices.IndexFunc(page.Threads, func(th ThreadSummary) bool { return slices.Contains(th.MessageIDs, "p1@example.org") })
	views, err := e.Thread(page.Threads[i].ID, r)
	if err != nil {
		t.Fatal(err)
	}
	plans := views[0]
	if plans.Doc == nil || !slices.Equal(plans.Doc.Lines, []string{"first"}) || !slices.Contains(plans.HeaderLines, "Subject: Plans") {
		t.Fatalf("view = %+v", plans)
	}
	if err := e.Tag([]string{"p1@example.org"}, []string{"+flagged"}); err != nil {
		t.Fatal(err)
	}
	again, err := e.Message("p1@example.org", nil, r)
	if err != nil || !slices.Contains(again.Tags, "flagged") || again.Doc == nil {
		t.Errorf("a cached view lost fresh tags: %+v %v", again, err)
	}
	quoted, _ := e.Message("p1@example.org", nil, &Render{Width: 72, InlineURLs: true})
	if quoted.Doc == nil || quoted.Doc == again.Doc {
		t.Error("different render options must not share a cached doc")
	}
	e.view.Raw = map[string]bool{"text/plain": true}
	e.views = viewCache{}
	raw, _ := e.Message("p1@example.org", nil, r)
	if raw.Doc != nil {
		t.Error("a message with a client-rendered type must leave rendering to the client")
	}
	laid, err := e.Layout(raw.Blocks, *r)
	if err != nil || !slices.Equal(laid.Lines, []string{"first"}) {
		t.Errorf("layout = %+v %v", laid, err)
	}
}
