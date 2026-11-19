package calendar

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

var request = strings.Join([]string{
	"BEGIN:VCALENDAR",
	"METHOD:REQUEST",
	"BEGIN:VTIMEZONE",
	"TZID:Europe/Copenhagen",
	"BEGIN:STANDARD",
	"TZOFFSETFROM:+0200",
	"TZOFFSETTO:+0100",
	"END:STANDARD",
	"END:VTIMEZONE",
	"BEGIN:VEVENT",
	"UID:abc-123",
	"SEQUENCE:2",
	"DTSTART;TZID=Europe/Copenhagen:20261120T100000",
	"DTEND;TZID=Europe/Copenhagen:20261120T110000",
	`SUMMARY:Team sync\, weekly`,
	`ORGANIZER;CN="Org, Anne":mailto:org@example.org`,
	"ATTENDEE;CN=Test User;RSVP=TRUE;PARTSTAT=NEEDS-ACTION;ROLE=REQ-PARTICIPANT:mai",
	" lto:ME@example.com",
	"BEGIN:VALARM",
	"TRIGGER:-PT15M",
	"SUMMARY:alarm",
	"END:VALARM",
	"END:VEVENT",
	"END:VCALENDAR",
}, "\r\n")

var at = time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)

func TestParseReadsMethodSummaryAndOrganizer(t *testing.T) {
	i, err := Parse(request)
	if err != nil {
		t.Fatal(err)
	}
	if i.Method != "REQUEST" || i.Summary != "Team sync, weekly" || i.Organizer == nil || *i.Organizer != (Person{Name: "Org, Anne", Address: "org@example.org"}) {
		t.Errorf("request = %+v organizer %+v", i, i.Organizer)
	}
}

func TestReplyAnswersAsTheMatchingAttendee(t *testing.T) {
	i, _ := Parse(request)
	reply, err := i.Reply(Person{Name: "Test User", Address: "me@example.com"}, Accepted, at)
	if err != nil {
		t.Fatal(err)
	}
	unfolded := strings.ReplaceAll(reply, "\r\n ", "")
	for _, want := range []string{
		"METHOD:REPLY\r\n",
		"BEGIN:VTIMEZONE\r\nTZID:Europe/Copenhagen\r\nBEGIN:STANDARD\r\n",
		"UID:abc-123\r\nSEQUENCE:2\r\n",
		`ORGANIZER;CN="Org, Anne":mailto:org@example.org`,
		"DTSTAMP:20261119T120000Z\r\n",
		"ATTENDEE;CN=Test User;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED:mailto:ME@example.com",
	} {
		if !strings.Contains(unfolded, want) {
			t.Errorf("reply lacks %q:\n%s", want, reply)
		}
	}
	if strings.Contains(reply, "RSVP") || strings.Contains(reply, "VALARM") {
		t.Errorf("reply kept RSVP or the alarm:\n%s", reply)
	}
	for line := range strings.SplitSeq(strings.TrimSuffix(reply, "\r\n"), "\r\n") {
		if len(line) > maxOctets {
			t.Errorf("unfolded line of %d octets: %q", len(line), line)
		}
	}
}

func TestReplyAddsAnAttendeeWhenTheInviteDoesNotListUs(t *testing.T) {
	i, _ := Parse(request)
	reply, err := i.Reply(Person{Name: "Doe, Jane", Address: "other@example.com"}, Declined, at)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.ReplaceAll(reply, "\r\n ", ""), `ATTENDEE;PARTSTAT=DECLINED;CN="Doe, Jane":mailto:other@example.com`) {
		t.Errorf("reply:\n%s", reply)
	}
	if _, err := i.Reply(Person{Address: "x@y"}, "MAYBE", at); err == nil {
		t.Error("an unknown status must be rejected")
	}
}

func TestFoldSplitsOnUTF8Boundaries(t *testing.T) {
	line := "SUMMARY:" + strings.Repeat("æ", 60)
	folded := Fold(line)
	for part := range strings.SplitSeq(folded, "\r\n") {
		if len(part) > maxOctets || !utf8.ValidString(part) {
			t.Errorf("bad fold %q", part)
		}
	}
	if strings.ReplaceAll(folded, "\r\n ", "") != line {
		t.Error("fold did not round-trip")
	}
}
