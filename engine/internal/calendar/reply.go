package calendar

import (
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

type PartStat string

const (
	Accepted  PartStat = "ACCEPTED"
	Declined  PartStat = "DECLINED"
	Tentative PartStat = "TENTATIVE"
)

type Person struct {
	Name    string
	Address string
}

type Invite struct {
	Method    string
	Summary   string
	Organizer *Person
	calendar  *comp
	event     *comp
}

const maxOctets = 75

var copied = []string{"UID", "SEQUENCE", "RECURRENCE-ID", "DTSTART", "DTEND", "DURATION", "SUMMARY", "ORGANIZER"}

func Parse(ics string) (Invite, error) {
	for _, root := range parseICS(ics) {
		if root.name != "VCALENDAR" {
			continue
		}
		invite := Invite{calendar: root}
		if method := root.prop("METHOD"); method != nil {
			invite.Method = strings.ToUpper(strings.TrimSpace(method.value))
		}
		for _, c := range root.comps {
			if c.name == "VEVENT" {
				invite.event = c
				break
			}
		}
		if invite.event == nil {
			return invite, nil
		}
		if summary := invite.event.prop("SUMMARY"); summary != nil {
			invite.Summary = strings.TrimSpace(unescapeText(summary.value))
		}
		if organizer := invite.event.prop("ORGANIZER"); organizer != nil {
			name, _ := organizer.param("CN")
			invite.Organizer = &Person{Name: name, Address: mailto(organizer.value)}
		}
		return invite, nil
	}
	return Invite{}, errors.New("no VCALENDAR in the calendar part")
}

func mailto(value string) string {
	if len(value) >= 7 && strings.EqualFold(value[:7], "mailto:") {
		return value[7:]
	}
	return value
}

func paramValue(value string) string {
	if strings.ContainsAny(value, ",;:") {
		return `"` + strings.ReplaceAll(value, `"`, "") + `"`
	}
	return value
}

func attendeeLine(event *comp, me Person, status PartStat) string {
	for _, attendee := range event.propsNamed("ATTENDEE") {
		if !strings.EqualFold(mailto(attendee.value), me.Address) {
			continue
		}
		parts := []string{"ATTENDEE"}
		for _, kv := range attendee.params {
			if kv[0] != "PARTSTAT" && kv[0] != "RSVP" {
				parts = append(parts, kv[0]+"="+paramValue(kv[1]))
			}
		}
		parts = append(parts, "PARTSTAT="+string(status))
		return strings.Join(parts, ";") + ":" + attendee.value
	}
	parts := []string{"ATTENDEE", "PARTSTAT=" + string(status)}
	if me.Name != "" {
		parts = append(parts, "CN="+paramValue(me.Name))
	}
	return strings.Join(parts, ";") + ":mailto:" + me.Address
}

func serialize(c *comp, lines []string) []string {
	lines = append(lines, "BEGIN:"+c.name)
	for _, p := range c.props {
		lines = append(lines, p.raw)
	}
	for _, child := range c.comps {
		lines = serialize(child, lines)
	}
	return append(lines, "END:"+c.name)
}

func Fold(line string) string {
	var out []string
	for len(line) > maxOctets {
		cut := maxOctets
		for cut > 1 && !utf8.RuneStart(line[cut]) {
			cut--
		}
		out = append(out, line[:cut])
		line = " " + line[cut:]
	}
	return strings.Join(append(out, line), "\r\n")
}

func (i Invite) Reply(me Person, status PartStat, now time.Time) (string, error) {
	switch status {
	case Accepted, Declined, Tentative:
	default:
		return "", fmt.Errorf("unknown participation status %q", status)
	}
	if i.event == nil {
		return "", errors.New("the invite has no VEVENT")
	}
	if i.event.prop("UID") == nil {
		return "", errors.New("the invite has no UID")
	}
	lines := []string{"BEGIN:VCALENDAR", "PRODID:-//email.nvim//EN", "VERSION:2.0", "METHOD:REPLY"}
	for _, c := range i.calendar.comps {
		if c.name == "VTIMEZONE" {
			lines = serialize(c, lines)
		}
	}
	lines = append(lines, "BEGIN:VEVENT")
	for _, name := range copied {
		if p := i.event.prop(name); p != nil {
			lines = append(lines, p.raw)
		}
	}
	lines = append(lines,
		"DTSTAMP:"+now.UTC().Format("20060102T150405Z"),
		attendeeLine(i.event, me, status),
		"END:VEVENT",
		"END:VCALENDAR",
	)
	for n, line := range lines {
		lines[n] = Fold(line)
	}
	return strings.Join(lines, "\r\n") + "\r\n", nil
}
