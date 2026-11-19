package doc

import (
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/mattn/go-runewidth"
)

type Options struct {
	Headings   []string `json:"headings"`
	Bullets    []string `json:"bullets"`
	Quote      string   `json:"quote"`
	Link       string   `json:"link"`
	Email      string   `json:"email"`
	Image      string   `json:"image"`
	Types      []string `json:"types"`
	InlineURLs bool     `json:"-"`
}

type Segment struct {
	Lines    []string
	Markdown bool
}

type Highlight struct {
	Row, Start, End int
	Group           string
}

func (h Highlight) MarshalJSON() ([]byte, error) {
	buf := make([]byte, 0, 32+len(h.Group))
	buf = append(buf, '[')
	buf = strconv.AppendInt(buf, int64(h.Row), 10)
	buf = append(buf, ',')
	buf = strconv.AppendInt(buf, int64(h.Start), 10)
	buf = append(buf, ',')
	buf = strconv.AppendInt(buf, int64(h.End), 10)
	buf = append(buf, ',')
	buf = strconv.AppendQuote(buf, h.Group)
	return append(buf, ']'), nil
}

type LineHighlight struct {
	Row   int
	Group string
}

func (h LineHighlight) MarshalJSON() ([]byte, error) {
	buf := make([]byte, 0, 16+len(h.Group))
	buf = append(buf, '[')
	buf = strconv.AppendInt(buf, int64(h.Row), 10)
	buf = append(buf, ',')
	buf = strconv.AppendQuote(buf, h.Group)
	return append(buf, ']'), nil
}

type Link struct {
	Row      int    `json:"row"`
	StartCol int    `json:"start_col"`
	EndCol   int    `json:"end_col"`
	URL      string `json:"url"`
}

type Image struct {
	Row    int    `json:"row"`
	Alt    string `json:"alt"`
	Source string `json:"source"`
}

type Doc struct {
	Lines          []string        `json:"lines"`
	Highlights     []Highlight     `json:"highlights"`
	LineHighlights []LineHighlight `json:"line_highlights"`
	Links          []Link          `json:"links"`
	Images         []Image         `json:"images"`
}

var cells = &runewidth.Condition{EastAsianWidth: false, StrictEmojiNeutral: true}

func Width(s string) int {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] >= 0x7f {
			return cells.StringWidth(s)
		}
	}
	return len(s)
}

type span struct {
	start, end int
	group      string
}

type link struct {
	start, end int
	url        string
}

type image struct {
	col         int
	alt, source string
}

type inline struct {
	text   string
	spans  []span
	links  []link
	images []image
}

type builder struct {
	text   strings.Builder
	spans  []span
	links  []link
	images []image
}

func (b *builder) push(text, group string) {
	if text == "" {
		return
	}
	start := b.text.Len()
	b.text.WriteString(text)
	if group != "" {
		b.spans = append(b.spans, span{start, b.text.Len(), group})
	}
}

func (b *builder) merge(sub inline, group, url string) {
	offset := b.text.Len()
	b.push(sub.text, "")
	for _, s := range sub.spans {
		b.spans = append(b.spans, span{s.start + offset, s.end + offset, s.group})
	}
	for _, l := range sub.links {
		b.links = append(b.links, link{l.start + offset, l.end + offset, l.url})
	}
	for _, im := range sub.images {
		b.images = append(b.images, image{im.col + offset, im.alt, im.source})
	}
	if group != "" {
		b.spans = append(b.spans, span{offset, b.text.Len(), group})
	}
	if url != "" {
		b.links = append(b.links, link{offset, b.text.Len(), url})
	}
}

func (b *builder) finish() inline {
	return inline{text: b.text.String(), spans: b.spans, links: b.links, images: b.images}
}

func closingBracket(s string, i int) int {
	depth := 0
	for j := i; j < len(s); {
		switch s[j] {
		case '\\':
			j += 2
			continue
		case '[':
			depth++
		case ']':
			depth--
			if depth == 0 {
				return j
			}
		}
		j++
	}
	return -1
}

func destination(s string, i int) (string, int, bool) {
	if i+1 < len(s) && s[i+1] == '<' {
		closing := strings.IndexByte(s[i+2:], '>')
		if closing >= 0 {
			closing += i + 2
			if closing+1 < len(s) && s[closing+1] == ')' {
				return s[i+2 : closing], closing + 2, true
			}
		}
		return "", 0, false
	}
	depth := 0
	for j := i; j < len(s); j++ {
		switch s[j] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				fields := strings.Fields(s[i+1 : j])
				if len(fields) == 0 {
					return "", 0, false
				}
				return fields[0], j + 1, true
			}
		}
	}
	return "", 0, false
}

func findUnescaped(s, needle string, from int) int {
	for j := from; j+len(needle) <= len(s); {
		if s[j] == '\\' {
			j += 2
			continue
		}
		if s[j:j+len(needle)] == needle {
			return j
		}
		j++
	}
	return -1
}

func isPunct(c byte) bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

var autolink = regexp.MustCompile(`^<(https?://[^>\s]+)>`)

func parseInline(s string, opts *Options) inline {
	var b builder
	var plain strings.Builder
	flush := func() {
		if plain.Len() > 0 {
			b.push(plain.String(), "")
			plain.Reset()
		}
	}
	for i := 0; i < len(s); {
		c := s[i]
		consumed := false
		switch {
		case c == '\\' && i+1 < len(s) && isPunct(s[i+1]):
			plain.WriteByte(s[i+1])
			i += 2
			consumed = true
		case c == '`':
			run := i
			for run < len(s) && s[run] == '`' {
				run++
			}
			fence := s[i:run]
			if closing := strings.Index(s[run:], fence); closing >= 0 {
				closing += run
				flush()
				b.push(s[run:closing], "EmailCode")
				i = closing + len(fence)
				consumed = true
			}
		case c == '!' && i+1 < len(s) && s[i+1] == '[':
			closing := closingBracket(s, i+1)
			if closing >= 0 && closing+1 < len(s) && s[closing+1] == '(' {
				if source, after, ok := destination(s, closing+1); ok {
					flush()
					alt := parseInline(s[i+2:closing], opts).text
					b.images = append(b.images, image{b.text.Len(), alt, source})
					b.push(opts.Image+alt, "EmailImage")
					i = after
					consumed = true
				}
			}
		case c == '[':
			closing := closingBracket(s, i)
			if closing >= 0 && closing+1 < len(s) && s[closing+1] == '(' {
				if url, after, ok := destination(s, closing+1); ok {
					flush()
					label := parseInline(s[i+1:closing], opts)
					if opts.InlineURLs {
						if label.text != url {
							label.text += " <" + url + ">"
						}
						b.merge(label, "", "")
					} else {
						icon := opts.Link
						if strings.HasPrefix(url, "mailto:") {
							icon = opts.Email
						}
						start := b.text.Len()
						b.push(icon, "")
						b.merge(label, "", "")
						b.spans = append(b.spans, span{start, b.text.Len(), "EmailLink"})
						b.links = append(b.links, link{start, b.text.Len(), url})
					}
					i = after
					consumed = true
				}
			}
		case c == '<':
			if m := autolink.FindStringSubmatch(s[i:]); m != nil {
				flush()
				start := b.text.Len()
				b.push(m[1], "EmailLink")
				b.links = append(b.links, link{start, b.text.Len(), m[1]})
				i += len(m[0])
				consumed = true
			}
		case c == '*' || c == '_':
			delim := string(c)
			if i+1 < len(s) && s[i+1] == c {
				delim += string(c)
			}
			closing := findUnescaped(s, delim, i+len(delim))
			if closing > i+len(delim) {
				flush()
				group := "EmailEmph"
				if len(delim) == 2 {
					group = "EmailStrong"
				}
				b.merge(parseInline(s[i+len(delim):closing], opts), group, "")
				i = closing + len(delim)
				consumed = true
			}
		}
		if !consumed {
			plain.WriteByte(c)
			i++
		}
	}
	flush()
	return b.finish()
}

type out struct {
	doc *Doc
}

func (o *out) emit(text string, spans []span, links []link, images []image, lineGroup string) {
	o.doc.Lines = append(o.doc.Lines, text)
	row := len(o.doc.Lines)
	if lineGroup != "" {
		o.doc.LineHighlights = append(o.doc.LineHighlights, LineHighlight{row, lineGroup})
	}
	for _, s := range spans {
		o.doc.Highlights = append(o.doc.Highlights, Highlight{row, s.start, s.end, s.group})
	}
	for _, l := range links {
		o.doc.Links = append(o.doc.Links, Link{row, l.start, l.end, l.url})
	}
	for index, im := range images {
		if index > 0 {
			o.doc.Lines = append(o.doc.Lines, "")
		}
		o.doc.Images = append(o.doc.Images, Image{len(o.doc.Lines), im.alt, im.source})
	}
}

func shiftSpans(list []span, offset int) []span {
	shifted := make([]span, len(list))
	for i, s := range list {
		shifted[i] = span{s.start + offset, s.end + offset, s.group}
	}
	return shifted
}

func shiftLinks(list []link, offset int) []link {
	shifted := make([]link, len(list))
	for i, l := range list {
		shifted[i] = link{l.start + offset, l.end + offset, l.url}
	}
	return shifted
}

func (o *out) emitInline(prefix, prefixGroup string, rendered inline, extraGroup, lineGroup string) {
	spans := make([]span, 0, len(rendered.spans)+2)
	if extraGroup != "" {
		spans = append(spans, span{len(prefix), len(prefix) + len(rendered.text), extraGroup})
	}
	if prefixGroup != "" && prefix != "" {
		spans = append(spans, span{0, len(prefix), prefixGroup})
	}
	spans = append(spans, shiftSpans(rendered.spans, len(prefix))...)
	o.emit(prefix+rendered.text, spans, shiftLinks(rendered.links, len(prefix)), rendered.images, lineGroup)
}

func splitRow(line string) []string {
	s := strings.TrimSpace(line)
	s = strings.TrimPrefix(s, "|")
	if strings.HasSuffix(s, "|") && !strings.HasSuffix(s, `\|`) {
		s = s[:len(s)-1]
	}
	var cells []string
	start := 0
	for j := 0; j < len(s); {
		switch s[j] {
		case '\\':
			j += 2
			continue
		case '|':
			cells = append(cells, strings.TrimSpace(s[start:j]))
			start = j + 1
		}
		j++
	}
	return append(cells, strings.TrimSpace(s[min(start, len(s)):]))
}

type align int

const (
	alignLeft align = iota
	alignCenter
	alignRight
)

var separatorCell = regexp.MustCompile(`^:?-+:?$`)

func isTableRow(line string) bool {
	return strings.HasPrefix(strings.TrimLeft(line, " \t"), "|")
}

func separatorAlignments(line string) []align {
	if !isTableRow(line) {
		return nil
	}
	cellsOf := splitRow(line)
	aligns := make([]align, len(cellsOf))
	for i, cell := range cellsOf {
		if !separatorCell.MatchString(cell) {
			return nil
		}
		left, right := strings.HasPrefix(cell, ":"), strings.HasSuffix(cell, ":")
		switch {
		case left && right:
			aligns[i] = alignCenter
		case right:
			aligns[i] = alignRight
		}
	}
	return aligns
}

type char struct {
	start, stop int
	space       bool
	width       int
}

func wrap(text string, width int) [][2]int {
	if Width(text) <= width {
		return [][2]int{{0, len(text)}}
	}
	chars := make([]char, 0, len(text))
	for i := 0; i < len(text); {
		r, size := utf8.DecodeRuneInString(text[i:])
		chars = append(chars, char{start: i, stop: i + size, space: r == ' ', width: Width(text[i : i+size])})
		i += size
	}
	var segments [][2]int
	closeSeg := func(first, last int) {
		for last >= first && chars[last].space {
			last--
		}
		if last >= first {
			segments = append(segments, [2]int{chars[first].start, chars[last].stop})
		}
	}
	for i := 0; i < len(chars); {
		for i < len(chars) && chars[i].space {
			i++
		}
		first, used, lastSpace := i, 0, -1
		for i < len(chars) && (used == 0 || used+chars[i].width <= width) {
			if chars[i].space {
				lastSpace = i
			}
			used += chars[i].width
			i++
		}
		switch {
		case i < len(chars) && lastSpace >= 0 && !chars[i].space:
			closeSeg(first, lastSpace-1)
			i = lastSpace + 1
		case first < len(chars):
			closeSeg(first, i-1)
		}
	}
	return segments
}

func columnWidths(natural []int, available int) []int {
	total := 0
	for _, w := range natural {
		total += w
	}
	if total <= available || available < len(natural) {
		return natural
	}
	widths := make([]int, len(natural))
	open := make([]bool, len(natural))
	count := len(natural)
	for c := range open {
		open[c] = true
	}
	left := available
	for changed := true; changed && count > 0; {
		changed = false
		share := left / count
		for c := range natural {
			if open[c] && natural[c] <= share {
				widths[c], open[c] = natural[c], false
				left -= natural[c]
				count--
				changed = true
			}
		}
	}
	if count == 0 {
		return widths
	}
	share, extra := left/count, left%count
	seen := 0
	for c := range natural {
		if !open[c] {
			continue
		}
		seen++
		widths[c] = share
		if seen <= extra {
			widths[c]++
		}
		widths[c] = max(1, widths[c])
	}
	return widths
}

func clipSpans(list []span, from, to, offset int) []span {
	var clipped []span
	for _, s := range list {
		start, end := max(s.start, from), min(s.end, to)
		if start < end {
			clipped = append(clipped, span{start - from + offset, end - from + offset, s.group})
		}
	}
	return clipped
}

func clipLinks(list []link, from, to, offset int) []link {
	var clipped []link
	for _, l := range list {
		start, end := max(l.start, from), min(l.end, to)
		if start < end {
			clipped = append(clipped, link{start - from + offset, end - from + offset, l.url})
		}
	}
	return clipped
}

const (
	cellOpen  = "│ "
	cellSep   = " │ "
	cellClose = " │"
)

func (o *out) table(header []string, aligns []align, rows [][]string, width int, opts *Options) {
	all := append([][]string{header}, rows...)
	columns := 0
	for _, row := range all {
		columns = max(columns, len(row))
	}
	rendered := make([][]inline, len(all))
	natural := make([]int, columns)
	for c := range natural {
		natural[c] = 1
	}
	for r, row := range all {
		rendered[r] = make([]inline, columns)
		for c := range columns {
			text := ""
			if c < len(row) {
				text = row[c]
			}
			cell := parseInline(text, opts)
			cell.images = nil
			rendered[r][c] = cell
			natural[c] = max(natural[c], Width(cell.text))
		}
	}
	widths := columnWidths(natural, width-(3*columns+1))
	border := func(left, mid, right string) {
		pieces := make([]string, columns)
		for c := range columns {
			pieces[c] = strings.Repeat("─", widths[c]+2)
		}
		line := left + strings.Join(pieces, mid) + right
		o.emit(line, []span{{0, len(line), "EmailTableBorder"}}, nil, nil, "")
	}
	border("┌", "┬", "┐")
	for r, row := range rendered {
		wrapped := make([][][2]int, columns)
		height := 1
		for c := range columns {
			wrapped[c] = wrap(row[c].text, widths[c])
			height = max(height, len(wrapped[c]))
		}
		for k := range height {
			var line strings.Builder
			line.WriteString(cellOpen)
			spans := []span{{0, len(cellOpen), "EmailTableBorder"}}
			var links []link
			offset := len(cellOpen)
			for c := range columns {
				cell := row[c]
				piece := ""
				var segment [2]int
				has := k < len(wrapped[c])
				if has {
					segment = wrapped[c][k]
					piece = cell.text[segment[0]:segment[1]]
				}
				pad := widths[c] - Width(piece)
				a := alignLeft
				if c < len(aligns) {
					a = aligns[c]
				}
				before := 0
				switch a {
				case alignRight:
					before = pad
				case alignCenter:
					before = pad / 2
				}
				line.WriteString(strings.Repeat(" ", max(before, 0)))
				offset += max(before, 0)
				if has {
					spans = append(spans, clipSpans(cell.spans, segment[0], segment[1], offset)...)
					links = append(links, clipLinks(cell.links, segment[0], segment[1], offset)...)
					if r == 0 {
						spans = append(spans, span{offset, offset + len(piece), "EmailTableHeader"})
					}
				}
				line.WriteString(piece)
				offset += len(piece)
				after := max(pad-before, 0)
				sep := cellSep
				if c == columns-1 {
					sep = cellClose
				}
				line.WriteString(strings.Repeat(" ", after))
				line.WriteString(sep)
				spans = append(spans, span{offset + after, offset + after + len(sep), "EmailTableBorder"})
				offset += after + len(sep)
			}
			o.emit(line.String(), spans, links, nil, "")
		}
		if r == 0 {
			border("├", "┼", "┤")
		}
	}
	border("└", "┴", "┘")
}

var (
	heading  = regexp.MustCompile(`^(#+)\s+(.*)$`)
	quote    = regexp.MustCompile(`^>[>\s]*`)
	bullet   = regexp.MustCompile(`^(\s*)([-*+])\s+(.*)$`)
	numbered = regexp.MustCompile(`^(\s*)(\d+)\.\s+(.*)$`)
	rule     = regexp.MustCompile(`^\s*(---+|\*\*\*+)\s*$`)
)

func isFence(line string) bool {
	return strings.HasPrefix(strings.TrimLeft(line, " \t"), "```")
}

func (o *out) markdown(lines []string, width int, opts *Options) {
	for i := 0; i < len(lines); {
		line := lines[i]
		var aligns []align
		if isTableRow(line) && i+1 < len(lines) {
			aligns = separatorAlignments(lines[i+1])
		}
		switch {
		case isFence(line):
			i++
			for i < len(lines) && !isFence(lines[i]) {
				o.emit(lines[i], []span{{0, len(lines[i]), "EmailCode"}}, nil, nil, "EmailCodeBlock")
				i++
			}
			i++
		case aligns != nil:
			header := splitRow(line)
			var rows [][]string
			for i += 2; i < len(lines) && isTableRow(lines[i]); i++ {
				rows = append(rows, splitRow(lines[i]))
			}
			o.table(header, aligns, rows, width, opts)
		default:
			o.block(line, width, opts)
			i++
		}
	}
}

func (o *out) block(line string, width int, opts *Options) {
	if m := heading.FindStringSubmatch(line); m != nil && len(m[1]) <= 6 {
		level := len(m[1])
		group := "EmailH" + strconv.Itoa(level)
		o.emitInline(opts.Headings[(level-1)%len(opts.Headings)], group, parseInline(m[2], opts), group, group+"Bg")
		return
	}
	if rule.MatchString(line) {
		r := strings.Repeat("─", width)
		o.emit(r, []span{{0, len(r), "EmailRule"}}, nil, nil, "")
		return
	}
	if q := quote.FindString(line); q != "" {
		depth := strings.Count(q, ">")
		o.emitInline(strings.Repeat(opts.Quote+" ", depth), "EmailQuote", parseInline(line[len(q):], opts), "", "")
		return
	}
	if m := bullet.FindStringSubmatch(line); m != nil {
		level := (len(m[1])/2)%len(opts.Bullets) + 1
		o.emitInline(m[1]+opts.Bullets[level-1]+" ", "EmailBullet", parseInline(m[3], opts), "", "")
		return
	}
	if m := numbered.FindStringSubmatch(line); m != nil {
		o.emitInline(m[1]+m[2]+". ", "EmailBullet", parseInline(m[3], opts), "", "")
		return
	}
	o.emitInline("", "", parseInline(line, opts), "", "")
}

func Render(segments []Segment, width int, opts Options) Doc {
	d := Doc{Lines: []string{}, Highlights: []Highlight{}, LineHighlights: []LineHighlight{}, Links: []Link{}, Images: []Image{}}
	o := out{doc: &d}
	for _, segment := range segments {
		if len(d.Lines) > 0 {
			d.Lines = append(d.Lines, "")
		}
		if segment.Markdown {
			o.markdown(segment.Lines, width, &opts)
		} else {
			d.Lines = append(d.Lines, segment.Lines...)
		}
	}
	return d
}

func Lines(s string) []string {
	lines := strings.Split(strings.ReplaceAll(s, "\r", ""), "\n")
	blank := func(line string) bool { return strings.TrimSpace(line) == "" }
	end := len(lines)
	for end > 0 && blank(lines[end-1]) {
		end--
	}
	start := 0
	for start < end && blank(lines[start]) {
		start++
	}
	return slices.Clip(lines[start:end])
}
