package compose

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"mime/quotedprintable"
	"net/mail"
	"path/filepath"
	"strings"
	"time"

	"github.com/stubbedev/email.nvim/engine/internal/markdown"
)

type Attachment struct {
	Filename string
	Data     []byte
}

type Calendar struct {
	ICS    string
	Method string
}

type Message struct {
	From        *mail.Address
	To          []*mail.Address
	Cc          []*mail.Address
	Bcc         []*mail.Address
	ReplyTo     []*mail.Address
	Subject     string
	InReplyTo   string
	References  string
	Body        string
	HTML        bool
	Calendar    *Calendar
	Attachments []Attachment
	Date        time.Time
	MessageID   string
}

const (
	maxLine       = 998
	base64Line    = 76
	boundaryBytes = 12
	uniqueBytes   = 8
)

func NewMessageID(at time.Time, domain string) (string, error) {
	unique, err := random(uniqueBytes)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%d.%s@%s", at.Unix(), unique, domain), nil
}

func random(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("reading random bytes: %w", err)
	}
	return hex.EncodeToString(buf), nil
}

func Domain(address *mail.Address) (string, error) {
	at := strings.LastIndexByte(address.Address, '@')
	if at < 0 || at == len(address.Address)-1 {
		return "", fmt.Errorf("address %q has no domain", address.Address)
	}
	return address.Address[at+1:], nil
}

func (m *Message) Recipients() []string {
	var out []string
	for _, list := range [][]*mail.Address{m.To, m.Cc, m.Bcc} {
		for _, address := range list {
			out = append(out, address.Address)
		}
	}
	return out
}

type writer struct {
	buf bytes.Buffer
}

func (w *writer) header(name, value string) {
	w.buf.WriteString(name)
	w.buf.WriteString(": ")
	w.buf.WriteString(value)
	w.buf.WriteByte('\n')
}

func wireAddress(address *mail.Address) string {
	if address.Name == "" {
		return address.Address
	}
	for i := 0; i < len(address.Name); i++ {
		if address.Name[i] >= 0x80 {
			return mime.QEncoding.Encode("utf-8", address.Name) + " <" + address.Address + ">"
		}
	}
	return Display(address)
}

func addressList(list []*mail.Address) string {
	formatted := make([]string, len(list))
	for i, address := range list {
		formatted[i] = wireAddress(address)
	}
	return strings.Join(formatted, ",\n ")
}

func (m *Message) Bytes(withBcc bool) ([]byte, error) {
	if m.From == nil {
		return nil, errors.New("building message: From is empty")
	}
	boundary, err := random(boundaryBytes)
	if err != nil {
		return nil, err
	}
	boundary = "=_" + boundary
	w := &writer{}
	w.header("Date", m.Date.UTC().Format(time.RFC1123Z))
	w.header("From", wireAddress(m.From))
	for _, field := range []struct {
		name string
		list []*mail.Address
	}{{"To", m.To}, {"Cc", m.Cc}, {"Bcc", m.Bcc}, {"Reply-To", m.ReplyTo}} {
		if len(field.list) == 0 || (field.name == "Bcc" && !withBcc) {
			continue
		}
		w.header(field.name, addressList(field.list))
	}
	if m.Subject != "" {
		w.header("Subject", mime.QEncoding.Encode("utf-8", m.Subject))
	}
	w.header("Message-ID", "<"+m.MessageID+">")
	if m.InReplyTo != "" {
		w.header("In-Reply-To", m.InReplyTo)
	}
	if m.References != "" {
		w.header("References", m.References)
	}
	w.header("MIME-Version", "1.0")
	body, err := m.bodyEntity(boundary + ".alt")
	if err != nil {
		return nil, err
	}
	if len(m.Attachments) == 0 {
		w.buf.Write(body)
		return w.buf.Bytes(), nil
	}
	w.header("Content-Type", mime.FormatMediaType("multipart/mixed", map[string]string{"boundary": boundary}))
	w.buf.WriteString("\n--" + boundary + "\n")
	w.buf.Write(body)
	for _, attachment := range m.Attachments {
		w.buf.WriteString("\n--" + boundary + "\n")
		contentType := mime.TypeByExtension(filepath.Ext(attachment.Filename))
		if contentType == "" {
			contentType = "application/octet-stream"
		}
		w.header("Content-Type", contentType)
		w.header("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": attachment.Filename}))
		w.header("Content-Transfer-Encoding", "base64")
		w.buf.WriteByte('\n')
		w.buf.WriteString(base64Lines(attachment.Data))
	}
	w.buf.WriteString("\n--" + boundary + "--\n")
	return w.buf.Bytes(), nil
}

func (m *Message) bodyEntity(boundary string) ([]byte, error) {
	type alternative struct {
		contentType string
		text        string
	}
	var alternatives []alternative
	if m.HTML {
		html, err := markdown.ToHTML(m.Body)
		if err != nil {
			return nil, err
		}
		alternatives = append(alternatives, alternative{
			contentType: "text/html; charset=utf-8",
			text:        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>" + html + "</body></html>\n",
		})
	}
	if m.Calendar != nil {
		method := m.Calendar.Method
		if method == "" {
			method = "REPLY"
		}
		alternatives = append(alternatives, alternative{
			contentType: mime.FormatMediaType("text/calendar", map[string]string{"charset": "utf-8", "method": method}),
			text:        m.Calendar.ICS,
		})
	}
	w := &writer{}
	if len(alternatives) == 0 {
		textPart(w, "text/plain; charset=utf-8", m.Body)
		return w.buf.Bytes(), nil
	}
	w.header("Content-Type", mime.FormatMediaType("multipart/alternative", map[string]string{"boundary": boundary}))
	w.buf.WriteString("\n--" + boundary + "\n")
	textPart(w, "text/plain; charset=utf-8", m.Body)
	for _, alt := range alternatives {
		w.buf.WriteString("\n--" + boundary + "\n")
		textPart(w, alt.contentType, alt.text)
	}
	w.buf.WriteString("\n--" + boundary + "--\n")
	return w.buf.Bytes(), nil
}

func textPart(w *writer, contentType, text string) {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	w.header("Content-Type", contentType)
	if !needsEncoding(text) {
		w.header("Content-Transfer-Encoding", "7bit")
		w.buf.WriteByte('\n')
		w.buf.WriteString(text)
		return
	}
	w.header("Content-Transfer-Encoding", "quoted-printable")
	w.buf.WriteByte('\n')
	w.buf.WriteString(quotedPrintable(text))
}

func needsEncoding(text string) bool {
	for line := range strings.SplitSeq(text, "\n") {
		if len(line) > maxLine {
			return true
		}
		for i := 0; i < len(line); i++ {
			if line[i] >= 0x80 {
				return true
			}
		}
	}
	return false
}

func quotedPrintable(text string) string {
	var buf bytes.Buffer
	qp := quotedprintable.NewWriter(&buf)
	_, _ = qp.Write([]byte(text))
	_ = qp.Close()
	return strings.ReplaceAll(buf.String(), "\r\n", "\n")
}

func base64Lines(data []byte) string {
	encoded := base64.StdEncoding.EncodeToString(data)
	var buf strings.Builder
	buf.Grow(len(encoded) + len(encoded)/base64Line + 1)
	for len(encoded) > base64Line {
		buf.WriteString(encoded[:base64Line])
		buf.WriteByte('\n')
		encoded = encoded[base64Line:]
	}
	buf.WriteString(encoded)
	buf.WriteByte('\n')
	return buf.String()
}
