package message

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"net/textproto"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/htmlindex"
)

type Message struct {
	Header textproto.MIMEHeader
	Root   *Part
}

type Part struct {
	ID          int
	ContentType string
	Params      map[string]string
	Disposition string
	Filename    string
	ContentID   string
	Children    []*Part
	Embedded    *Message
	Body        []byte
}

var words = &mime.WordDecoder{CharsetReader: charsetReader}

func charsetReader(charset string, input io.Reader) (io.Reader, error) {
	encoding, err := htmlindex.Get(charset)
	if err != nil {
		return nil, fmt.Errorf("unknown charset %q: %w", charset, err)
	}
	return encoding.NewDecoder().Reader(input), nil
}

func Parse(raw []byte) (*Message, error) {
	next := 1
	return parseMessage(raw, &next)
}

func parseMessage(raw []byte, next *int) (*Message, error) {
	reader := textproto.NewReader(bufio.NewReader(bytes.NewReader(raw)))
	header, err := reader.ReadMIMEHeader()
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("reading message header: %w", err)
	}
	body, err := io.ReadAll(reader.R)
	if err != nil {
		return nil, fmt.Errorf("reading message body: %w", err)
	}
	root, err := parsePart(header, body, next)
	if err != nil {
		return nil, err
	}
	return &Message{Header: header, Root: root}, nil
}

func parsePart(header textproto.MIMEHeader, body []byte, next *int) (*Part, error) {
	part := &Part{ID: *next}
	*next++
	part.ContentType, part.Params = mediaType(header.Get("Content-Type"))
	if disposition, params, err := mime.ParseMediaType(header.Get("Content-Disposition")); err == nil {
		part.Disposition = strings.ToLower(disposition)
		part.Filename = decodeWords(params["filename"])
	}
	if part.Filename == "" {
		part.Filename = decodeWords(part.Params["name"])
	}
	part.ContentID = strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(header.Get("Content-Id")), "<"), ">")
	switch {
	case strings.HasPrefix(part.ContentType, "multipart/") && part.Params["boundary"] != "":
		children, err := parseMultipart(body, part.Params["boundary"], next)
		if err != nil {
			return nil, fmt.Errorf("part %d (%s): %w", part.ID, part.ContentType, err)
		}
		part.Children = children
	case part.ContentType == "message/rfc822":
		decoded, err := decodeTransfer(header.Get("Content-Transfer-Encoding"), body)
		if err != nil {
			return nil, fmt.Errorf("part %d: %w", part.ID, err)
		}
		embedded, err := parseMessage(decoded, next)
		if err != nil {
			return nil, fmt.Errorf("part %d (attached message): %w", part.ID, err)
		}
		part.Embedded = embedded
		part.Body = decoded
	default:
		decoded, err := decodeTransfer(header.Get("Content-Transfer-Encoding"), body)
		if err != nil {
			return nil, fmt.Errorf("part %d (%s): %w", part.ID, part.ContentType, err)
		}
		part.Body = decoded
	}
	return part, nil
}

func mediaType(value string) (string, map[string]string) {
	media, params, err := mime.ParseMediaType(value)
	if err != nil && !errors.Is(err, mime.ErrInvalidMediaParameter) {
		return "text/plain", map[string]string{}
	}
	if params == nil {
		params = map[string]string{}
	}
	return strings.ToLower(media), params
}

func parseMultipart(body []byte, boundary string, next *int) ([]*Part, error) {
	reader := multipart.NewReader(bytes.NewReader(body), boundary)
	var children []*Part
	for {
		raw, err := reader.NextRawPart()
		if errors.Is(err, io.EOF) || (err != nil && len(children) > 0 && errors.Is(err, io.ErrUnexpectedEOF)) {
			return children, nil
		}
		if err != nil {
			return children, fmt.Errorf("reading multipart: %w", err)
		}
		content, err := io.ReadAll(raw)
		if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) {
			return children, fmt.Errorf("reading multipart: %w", err)
		}
		child, err := parsePart(raw.Header, content, next)
		if err != nil {
			return children, err
		}
		children = append(children, child)
	}
}

func decodeTransfer(encoding string, body []byte) ([]byte, error) {
	switch strings.ToLower(strings.TrimSpace(encoding)) {
	case "base64":
		cleaned := bytes.Map(func(r rune) rune {
			if r == '\r' || r == '\n' || r == ' ' || r == '\t' {
				return -1
			}
			return r
		}, body)
		cleaned = bytes.TrimRight(cleaned, "=")
		decoded := make([]byte, base64.RawStdEncoding.DecodedLen(len(cleaned)))
		n, err := base64.RawStdEncoding.Decode(decoded, cleaned)
		if err != nil {
			return nil, fmt.Errorf("decoding base64: %w", err)
		}
		return decoded[:n], nil
	case "quoted-printable":
		decoded, err := io.ReadAll(quotedprintable.NewReader(bytes.NewReader(body)))
		if err != nil {
			return nil, fmt.Errorf("decoding quoted-printable: %w", err)
		}
		return decoded, nil
	default:
		return body, nil
	}
}

func decodeWords(value string) string {
	if value == "" {
		return ""
	}
	decoded, err := words.DecodeHeader(value)
	if err != nil {
		return value
	}
	return decoded
}

func (m *Message) Get(name string) string {
	values := m.Header.Values(name)
	if len(values) == 0 {
		return ""
	}
	return toUTF8(decodeWords(unfold(values[0])), "")
}

func (m *Message) All(name string) []string {
	values := m.Header.Values(name)
	out := make([]string, len(values))
	for i, value := range values {
		out[i] = toUTF8(decodeWords(unfold(value)), "")
	}
	return out
}

var addresses = &mail.AddressParser{WordDecoder: words}

func ParseAddresses(value string) []*mail.Address {
	value = unfold(value)
	if value == "" {
		return nil
	}
	if list, err := addresses.ParseList(value); err == nil {
		return list
	}
	var out []*mail.Address
	for item := range strings.SplitSeq(value, ",") {
		if address, err := addresses.Parse(item); err == nil {
			out = append(out, address)
		}
	}
	return out
}

func (m *Message) Addresses(names ...string) []*mail.Address {
	var out []*mail.Address
	for _, name := range names {
		for _, value := range m.Header.Values(name) {
			out = append(out, ParseAddresses(value)...)
		}
	}
	return out
}

func ReadHeader(r io.Reader) (*Message, error) {
	header, err := textproto.NewReader(bufio.NewReader(r)).ReadMIMEHeader()
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("reading message header: %w", err)
	}
	return &Message{Header: header}, nil
}

func unfold(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func (p *Part) Text() string {
	return strings.ReplaceAll(toUTF8(string(p.Body), p.Params["charset"]), "\r\n", "\n")
}

func toUTF8(text, charset string) string {
	charset = strings.ToLower(strings.TrimSpace(charset))
	if charset != "" && charset != "utf-8" && charset != "us-ascii" && charset != "utf8" {
		if encoding, err := htmlindex.Get(charset); err == nil {
			if decoded, err := encoding.NewDecoder().String(text); err == nil {
				return decoded
			}
		}
	}
	if utf8.ValidString(text) {
		return text
	}
	return strings.ToValidUTF8(text, "�")
}

func (m *Message) Find(id int) *Part {
	return m.Root.find(id)
}

func (p *Part) find(id int) *Part {
	if p.ID == id {
		return p
	}
	for _, child := range p.Children {
		if found := child.find(id); found != nil {
			return found
		}
	}
	if p.Embedded != nil {
		return p.Embedded.Root.find(id)
	}
	return nil
}

func (p *Part) Walk(visit func(*Part)) {
	visit(p)
	for _, child := range p.Children {
		child.Walk(visit)
	}
	if p.Embedded != nil {
		p.Embedded.Root.Walk(visit)
	}
}
