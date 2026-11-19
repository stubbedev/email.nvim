package markdown

import (
	"bytes"
	"fmt"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/renderer/html"
)

var converter = goldmark.New(
	goldmark.WithExtensions(extension.Table, extension.Strikethrough, extension.Linkify),
	goldmark.WithRendererOptions(html.WithHardWraps()),
)

func ToHTML(source string) (string, error) {
	var out bytes.Buffer
	if err := converter.Convert([]byte(source), &out); err != nil {
		return "", fmt.Errorf("rendering Markdown as HTML: %w", err)
	}
	return out.String(), nil
}
