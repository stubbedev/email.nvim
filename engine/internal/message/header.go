package message

import (
	"bytes"
	"net/textproto"
	"strings"
)

func nextLine(raw []byte, at int) (line []byte, next int) {
	end := bytes.IndexByte(raw[at:], '\n')
	if end < 0 {
		return bytes.TrimSuffix(raw[at:], []byte("\r")), len(raw)
	}
	return bytes.TrimSuffix(raw[at:at+end], []byte("\r")), at + end + 1
}

func fieldName(name string) bool {
	if name == "" {
		return false
	}
	for i := 0; i < len(name); i++ {
		if name[i] < 33 || name[i] > 126 {
			return false
		}
	}
	return true
}

func splitHeader(raw []byte) (textproto.MIMEHeader, []byte) {
	header := textproto.MIMEHeader{}
	var name string
	at := 0
	for at < len(raw) {
		line, next := nextLine(raw, at)
		at = next
		if len(line) == 0 {
			return header, raw[at:]
		}
		if line[0] == ' ' || line[0] == '\t' {
			if values := header[name]; len(values) > 0 {
				values[len(values)-1] += " " + strings.TrimSpace(string(line))
			}
			continue
		}
		before, after, found := bytes.Cut(line, []byte(":"))
		field := strings.TrimRight(string(before), " \t")
		if !found || !fieldName(field) {
			name = ""
			continue
		}
		name = textproto.CanonicalMIMEHeaderKey(field)
		header[name] = append(header[name], strings.TrimSpace(string(after)))
	}
	return header, nil
}

func splitMultipart(body []byte, boundary string) [][]byte {
	delimiter := "--" + boundary
	var parts [][]byte
	start := -1
	at := 0
	for at < len(body) {
		lineStart := at
		line, next := nextLine(body, at)
		at = next
		trimmed := strings.TrimRight(string(line), " \t")
		if trimmed != delimiter && trimmed != delimiter+"--" {
			continue
		}
		if start >= 0 {
			end := lineStart
			if end > start && body[end-1] == '\n' {
				end--
				if end > start && body[end-1] == '\r' {
					end--
				}
			}
			parts = append(parts, body[start:end])
		}
		if trimmed == delimiter+"--" {
			return parts
		}
		start = at
	}
	if start >= 0 && start < len(body) {
		parts = append(parts, body[start:])
	}
	return parts
}
