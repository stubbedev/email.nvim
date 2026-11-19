package engine

import (
	"strconv"
	"strings"
	"sync"

	"github.com/stubbedev/email.nvim/engine/internal/doc"
	"github.com/stubbedev/email.nvim/engine/internal/view"
)

const viewCacheBytes = 64 << 20

type renderedView struct {
	view        view.View
	sender      string
	headerLines []string
	doc         *doc.Doc
	docJSON     []byte
	size        int
}

type viewCache struct {
	mu      sync.Mutex
	entries map[string]renderedView
	order   []string
	size    int
}

func viewKey(file string, opts view.Options, r *Render) string {
	var b strings.Builder
	b.WriteString(file)
	b.WriteByte(0)
	b.WriteString(strings.Join(opts.Alternatives, ","))
	if opts.Images {
		b.WriteString("\x00images")
	}
	if r != nil {
		b.WriteString("\x00w")
		b.WriteString(strconv.Itoa(r.Width))
		if r.InlineURLs {
			b.WriteString("\x00inline")
		}
		if r.Plain {
			b.WriteString("\x00plain")
		}
	}
	return b.String()
}

func sizeOf(v view.View, d *doc.Doc) int {
	size := 0
	for _, b := range v.Blocks {
		size += len(b.Content)
	}
	if d != nil {
		for _, line := range d.Lines {
			size += len(line)
		}
		size += 32 * (len(d.Highlights) + len(d.Links))
	}
	return size
}

func (c *viewCache) get(key string) (renderedView, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	return entry, ok
}

func (c *viewCache) put(key string, entry renderedView) {
	if entry.size > viewCacheBytes/4 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = map[string]renderedView{}
	}
	if _, ok := c.entries[key]; ok {
		return
	}
	for c.size+entry.size > viewCacheBytes && len(c.order) > 0 {
		oldest := c.order[0]
		c.order = c.order[1:]
		c.size -= c.entries[oldest].size
		delete(c.entries, oldest)
	}
	c.entries[key] = entry
	c.order = append(c.order, key)
	c.size += entry.size
}
