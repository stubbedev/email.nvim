package engine

import (
	"errors"
	"slices"

	"github.com/stubbedev/email.nvim/engine/internal/doc"
	"github.com/stubbedev/email.nvim/engine/internal/view"
)

type Render struct {
	Width      int  `json:"width"`
	InlineURLs bool `json:"inline_urls"`
	Plain      bool `json:"plain"`
}

const attachedMarker = "---------- Attached message ----------"

var summaryHeaders = []string{"From", "To", "Cc", "Date", "Subject"}

func headerLines(headers map[string]string) []string {
	lines := make([]string, 0, len(summaryHeaders))
	for _, name := range summaryHeaders {
		if value := headers[name]; value != "" {
			lines = append(lines, name+": "+value)
		}
	}
	return lines
}

func (e *Engine) renderable(blocks []view.Block) bool {
	return !slices.ContainsFunc(blocks, func(b view.Block) bool {
		return b.Kind == view.TextBlock && e.view.Raw[b.ContentType]
	})
}

func (e *Engine) layout(blocks []view.Block, r Render) (doc.Doc, error) {
	if len(e.markdown.Headings) == 0 || len(e.markdown.Bullets) == 0 {
		return doc.Doc{}, errors.New("rendering needs markdown options with headings and bullets; pass them to configure")
	}
	opts := e.markdown
	opts.InlineURLs = r.InlineURLs
	segments := make([]doc.Segment, 0, len(blocks))
	for _, b := range blocks {
		if b.Kind == view.HeadersBlock {
			segments = append(segments, doc.Segment{Lines: append([]string{attachedMarker}, headerLines(b.Headers)...)})
			continue
		}
		segments = append(segments, doc.Segment{
			Lines:    doc.Lines(b.Content),
			Markdown: !r.Plain && slices.Contains(opts.Types, b.ContentType),
		})
	}
	return doc.Render(segments, r.Width, opts), nil
}

func (e *Engine) Layout(blocks []view.Block, r Render) (doc.Doc, error) { return e.layout(blocks, r) }
