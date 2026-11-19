package engine

import (
	"bytes"
	"cmp"
	"context"
	"errors"
	"fmt"
	"net/mail"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/stubbedev/email.nvim/engine/internal/calendar"
	"github.com/stubbedev/email.nvim/engine/internal/compose"
	"github.com/stubbedev/email.nvim/engine/internal/maildir"
	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
	"github.com/stubbedev/email.nvim/engine/internal/smtp"
)

type CalendarPart struct {
	ICS    string `json:"ics"`
	Method string `json:"method"`
}

type Draft struct {
	From        string        `json:"from"`
	To          string        `json:"to"`
	Cc          string        `json:"cc"`
	Bcc         string        `json:"bcc"`
	ReplyTo     string        `json:"reply_to_header"`
	Subject     string        `json:"subject"`
	InReplyTo   string        `json:"in_reply_to"`
	References  string        `json:"references"`
	Body        string        `json:"body"`
	Attachments []string      `json:"attachments"`
	Calendar    *CalendarPart `json:"calendar"`
	Replying    string        `json:"replying"`
	DraftID     string        `json:"draft_id"`
}

const passwordTimeout = 30 * time.Second

func addresses(field, value string) ([]*mail.Address, error) {
	if strings.TrimSpace(value) == "" {
		return nil, nil
	}
	list, err := mail.ParseAddressList(value)
	if err != nil {
		return nil, fmt.Errorf("the %s header %q: %w", field, value, err)
	}
	return list, nil
}

func (e *Engine) build(d Draft, sending bool) (*Account, *compose.Message, error) {
	if len(e.accounts) == 0 {
		return nil, nil, errNoAccounts
	}
	from, err := mail.ParseAddress(d.From)
	if err != nil {
		return nil, nil, fmt.Errorf("the From header %q: %w", d.From, err)
	}
	account, err := e.accountFor(from.Address)
	if err != nil {
		return nil, nil, fmt.Errorf("the From header: %w", err)
	}
	domain, err := compose.Domain(from)
	if err != nil {
		return nil, nil, fmt.Errorf("the From header: %w", err)
	}
	now := time.Now()
	id, err := compose.NewMessageID(now, domain)
	if err != nil {
		return nil, nil, err
	}
	m := &compose.Message{
		From: from, Subject: d.Subject, InReplyTo: d.InReplyTo, References: d.References,
		Body: d.Body, HTML: sending && e.html, Date: now, MessageID: id,
	}
	for _, field := range []struct {
		name  string
		value string
		into  *[]*mail.Address
	}{{"To", d.To, &m.To}, {"Cc", d.Cc, &m.Cc}, {"Bcc", d.Bcc, &m.Bcc}, {"Reply-To", d.ReplyTo, &m.ReplyTo}} {
		if *field.into, err = addresses(field.name, field.value); err != nil {
			return nil, nil, err
		}
	}
	if sending && len(m.Recipients()) == 0 {
		return nil, nil, errors.New("the message has no recipients")
	}
	if d.Calendar != nil {
		m.Calendar = &compose.Calendar{ICS: d.Calendar.ICS, Method: d.Calendar.Method}
	}
	for _, path := range d.Attachments {
		data, err := os.ReadFile(path) //nolint:gosec
		if err != nil {
			return nil, nil, fmt.Errorf("reading attachment: %w", err)
		}
		m.Attachments = append(m.Attachments, compose.Attachment{Filename: filepath.Base(path), Data: data})
	}
	return account, m, nil
}

func (e *Engine) store(db *notmuch.Database, account *Account, folder string, data []byte, flags string, changes []notmuch.TagChange) (string, error) {
	path, err := maildir.Deliver(account.Root, folder, data, flags)
	if err != nil {
		return "", err
	}
	id, err := db.Index(path)
	if err != nil {
		return "", err
	}
	return id, db.Tag([]string{id}, changes)
}

func (e *Engine) removeDraft(db *notmuch.Database, id string) error {
	if id == "" {
		return nil
	}
	m, err := db.Message(id)
	if errors.Is(err, notmuch.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, account := range e.accounts {
		for _, file := range m.Files {
			folder, _, ok := maildir.Split(file, account.Root)
			if !ok || folder != account.Drafts {
				continue
			}
			if err := os.Remove(file); err != nil && !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("removing draft %s: %w", file, err)
			}
			if err := db.Remove(file); err != nil {
				return err
			}
		}
	}
	return nil
}

func (e *Engine) CheckDraft(d Draft) error {
	_, _, err := e.build(d, true)
	return err
}

func (e *Engine) SaveDraft(d Draft) (string, error) {
	account, m, err := e.build(d, false)
	if err != nil {
		return "", err
	}
	data, err := m.Bytes(true)
	if err != nil {
		return "", err
	}
	var id string
	err = e.write(func(db *notmuch.Database) error {
		id, err = e.store(db, account, account.Drafts, data, "DS", []notmuch.TagChange{
			{Tag: "draft", Add: true}, {Tag: "inbox", Add: false}, {Tag: "unread", Add: false},
		})
		if err != nil {
			return err
		}
		return e.removeDraft(db, d.DraftID)
	})
	return id, err
}

func password(ctx context.Context, argv []string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, passwordTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...) //nolint:gosec
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("password command %s: %w: %s", argv[0], err, strings.TrimSpace(stderr.String()))
	}
	line, _, _ := strings.Cut(string(out), "\n")
	return strings.TrimRight(line, "\r"), nil
}

func (e *Engine) Send(ctx context.Context, d Draft) error {
	account, m, err := e.build(d, true)
	if err != nil {
		return err
	}
	if account.SMTP == nil {
		return fmt.Errorf("account %s has no smtp server configured", account.Name)
	}
	wire, err := m.Bytes(false)
	if err != nil {
		return err
	}
	stored, err := m.Bytes(true)
	if err != nil {
		return err
	}
	server := smtp.Server{
		Host: account.SMTP.Host, Port: account.SMTP.Port, Security: account.SMTP.Security,
		User: account.SMTP.User, Auth: account.SMTP.Auth,
	}
	if len(account.SMTP.PasswordCmd) > 0 {
		if server.Password, err = password(ctx, account.SMTP.PasswordCmd); err != nil {
			return fmt.Errorf("account %s: %w", account.Name, err)
		}
	}
	if err := smtp.Send(ctx, server, m.From.Address, m.Recipients(), wire); err != nil {
		return err
	}
	err = e.write(func(db *notmuch.Database) error {
		if _, err := e.store(db, account, account.Sent, stored, "S", []notmuch.TagChange{
			{Tag: "sent", Add: true}, {Tag: "inbox", Add: false}, {Tag: "unread", Add: false},
		}); err != nil {
			return err
		}
		if d.Replying != "" {
			if err := db.Tag([]string{d.Replying}, []notmuch.TagChange{{Tag: "replied", Add: true}}); err != nil {
				return err
			}
		}
		return e.removeDraft(db, d.DraftID)
	})
	if err != nil {
		return fmt.Errorf("the message was sent, but filing it failed: %w", err)
	}
	return nil
}

type CalendarDraft struct {
	ReplyHeaders
	Body     string `json:"body"`
	ICS      string `json:"ics"`
	Label    string `json:"label"`
	Replying string `json:"replying"`
}

var partStatWords = map[calendar.PartStat]struct{ subject, verb string }{
	calendar.Accepted:  {"Accepted", "accepted"},
	calendar.Declined:  {"Declined", "declined"},
	calendar.Tentative: {"Tentative", "tentatively accepted"},
}

func (e *Engine) CalendarReply(id string, status calendar.PartStat, preferred int) (CalendarDraft, error) {
	words, ok := partStatWords[status]
	if !ok {
		return CalendarDraft{}, fmt.Errorf("unknown participation status %q", status)
	}
	m, err := e.Message(id, nil)
	if err != nil {
		return CalendarDraft{}, err
	}
	if len(m.Calendars) == 0 {
		return CalendarDraft{}, errors.New("this message has no calendar invite")
	}
	invite, err := calendar.Parse(m.Calendars[0].Content)
	if err != nil {
		return CalendarDraft{}, err
	}
	if invite.Method != "REQUEST" {
		return CalendarDraft{}, fmt.Errorf("the calendar part is %q, not an invitation (REQUEST)", invite.Method)
	}
	reply, err := e.Reply(id, false, preferred)
	if err != nil {
		return CalendarDraft{}, err
	}
	if invite.Organizer != nil {
		reply.To = compose.Display(&mail.Address{Name: invite.Organizer.Name, Address: invite.Organizer.Address})
	}
	reply.Cc = ""
	reply.Subject = words.subject + ": " + cmp.Or(invite.Summary, m.Headers["Subject"])
	ics, err := invite.Reply(calendar.Person{Name: reply.Name, Address: reply.Address}, status, time.Now())
	if err != nil {
		return CalendarDraft{}, err
	}
	return CalendarDraft{
		ReplyHeaders: reply,
		Body:         fmt.Sprintf("%s has %s the invitation.", cmp.Or(reply.Name, reply.Address), words.verb),
		ICS:          ics,
		Label:        words.subject,
		Replying:     id,
	}, nil
}
