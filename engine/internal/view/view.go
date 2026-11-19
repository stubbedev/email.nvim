package view

import (
	"strconv"
	"strings"

	"github.com/stubbedev/email.nvim/engine/internal/calendar"
	"github.com/stubbedev/email.nvim/engine/internal/convert"
	"github.com/stubbedev/email.nvim/engine/internal/message"
	"github.com/stubbedev/email.nvim/engine/internal/plain"
)

type BlockKind string

const (
	TextBlock    BlockKind = "text"
	HeadersBlock BlockKind = "headers"
)

type Block struct {
	Kind        BlockKind         `json:"kind"`
	ContentType string            `json:"content_type,omitempty"`
	Content     string            `json:"content,omitempty"`
	Headers     map[string]string `json:"headers,omitempty"`
}

type Attachment struct {
	Part        int    `json:"part"`
	Filename    string `json:"filename"`
	ContentType string `json:"content_type"`
	Size        int    `json:"size"`
}

type Image struct {
	Part        int    `json:"part"`
	ContentType string `json:"content_type"`
	ContentID   string `json:"content_id,omitempty"`
	Filename    string `json:"filename,omitempty"`
	Attachment  bool   `json:"attachment"`
}

type Calendar struct {
	Content string `json:"content"`
	Method  string `json:"method,omitempty"`
	Summary string `json:"summary,omitempty"`
}

type View struct {
	Headers     map[string]string `json:"headers"`
	Blocks      []Block           `json:"blocks"`
	Attachments []Attachment      `json:"attachments"`
	Calendars   []Calendar        `json:"calendars"`
	Images      []Image           `json:"images"`
}

type Options struct {
	Alternatives []string
	Raw          map[string]bool
	Images       bool
}

var MessageHeaders = []string{"From", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To", "References"}

var attachedHeaders = []string{"From", "To", "Cc", "Date", "Subject"}

func Headers(m *message.Message, names []string) map[string]string {
	out := make(map[string]string, len(names))
	for _, name := range names {
		if value := m.Get(name); value != "" {
			out[name] = value
		}
	}
	return out
}

func Build(m *message.Message, opts Options) View {
	v := View{
		Headers:     Headers(m, MessageHeaders),
		Blocks:      []Block{},
		Attachments: []Attachment{},
		Calendars:   []Calendar{},
		Images:      []Image{},
	}
	walk(m.Root, opts, &v)
	m.Root.Walk(func(p *message.Part) { collect(p, &v) })
	return v
}

func effectiveType(p *message.Part) string {
	if p.ContentType == "multipart/related" && len(p.Children) > 0 {
		return effectiveType(p.Children[0])
	}
	return p.ContentType
}

func chooseAlternative(parts []*message.Part, preference []string) *message.Part {
	for _, wanted := range preference {
		for _, part := range parts {
			if effectiveType(part) == wanted {
				return part
			}
		}
	}
	return parts[len(parts)-1]
}

func walk(p *message.Part, opts Options, v *View) {
	switch {
	case p.ContentType == "multipart/alternative" && len(p.Children) > 0:
		walk(chooseAlternative(p.Children, opts.Alternatives), opts, v)
	case p.ContentType == "multipart/signed" && len(p.Children) > 0:
		walk(p.Children[0], opts, v)
	case strings.HasPrefix(p.ContentType, "multipart/"):
		for _, child := range p.Children {
			walk(child, opts, v)
		}
	case p.Embedded != nil:
		v.Blocks = append(v.Blocks, Block{Kind: HeadersBlock, Headers: Headers(p.Embedded, attachedHeaders)})
		walk(p.Embedded.Root, opts, v)
	case strings.HasPrefix(p.ContentType, "text/") && p.Disposition != "attachment":
		v.Blocks = append(v.Blocks, Block{Kind: TextBlock, ContentType: p.ContentType, Content: render(p, opts)})
	case p.Filename != "" || p.Disposition == "attachment":
		filename := p.Filename
		if filename == "" {
			filename = "part-" + strconv.Itoa(p.ID)
		}
		v.Attachments = append(v.Attachments, Attachment{Part: p.ID, Filename: filename, ContentType: p.ContentType, Size: len(p.Body)})
	}
}

func collect(p *message.Part, v *View) {
	switch {
	case p.ContentType == "text/calendar" || p.ContentType == "application/ics":
		content := p.Text()
		entry := Calendar{Content: content}
		if invite, err := calendar.Parse(content); err == nil {
			entry.Method, entry.Summary = invite.Method, invite.Summary
		}
		v.Calendars = append(v.Calendars, entry)
	case strings.HasPrefix(p.ContentType, "image/"):
		v.Images = append(v.Images, Image{
			Part:        p.ID,
			ContentType: p.ContentType,
			ContentID:   p.ContentID,
			Filename:    p.Filename,
			Attachment:  p.Disposition == "attachment" || (p.Filename != "" && p.Disposition != "inline"),
		})
	}
}

func render(p *message.Part, opts Options) string {
	text := p.Text()
	if opts.Raw[p.ContentType] {
		return text
	}
	switch p.ContentType {
	case "text/html":
		return convert.Convert(text, convert.Options{Images: opts.Images})
	case "text/plain":
		return plain.Render(text, strings.EqualFold(p.Params["format"], "flowed"))
	case "text/calendar":
		return calendar.Convert(text)
	default:
		return text
	}
}
