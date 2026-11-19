package doc

import (
	"slices"
	"strings"
	"testing"
)

var opts = Options{
	Headings: []string{"H1 ", "H2 "},
	Bullets:  []string{"*", "-"},
	Quote:    "|",
	Link:     "L ",
	Email:    "E ",
	Image:    "I ",
}

func md(lines []string, width int, inlineURLs bool) Doc {
	o := opts
	o.InlineURLs = inlineURLs
	return Render([]Segment{{Lines: lines, Markdown: true}}, width, o)
}

type styled struct{ text, group string }

func spansOn(d Doc, row int) []styled {
	var out []styled
	for _, h := range d.Highlights {
		if h.Row == row {
			out = append(out, styled{d.Lines[row-1][h.Start:h.End], h.Group})
		}
	}
	return out
}

func TestLinksRenderAsTheirLabel(t *testing.T) {
	d := md([]string{"See [the docs](https://x.com/a_b) and [me](mailto:a@b.c)."}, 40, false)
	if !slices.Equal(d.Lines, []string{"See L the docs and E me."}) {
		t.Fatalf("lines = %q", d.Lines)
	}
	want := []Link{{1, 4, 14, "https://x.com/a_b"}, {1, 19, 23, "mailto:a@b.c"}}
	if !slices.Equal(d.Links, want) {
		t.Errorf("links = %+v", d.Links)
	}
	if got := spansOn(d, 1); !slices.Equal(got, []styled{{"L the docs", "EmailLink"}, {"E me", "EmailLink"}}) {
		t.Errorf("spans = %+v", got)
	}
}

func TestEmphasisCodeAndEscapesLoseTheirMarkers(t *testing.T) {
	d := md([]string{"**bold** *it* `co*de` a \\* b \\_c\\_ <https://y.org>"}, 40, false)
	if !slices.Equal(d.Lines, []string{"bold it co*de a * b _c_ https://y.org"}) {
		t.Fatalf("lines = %q", d.Lines)
	}
	want := []styled{{"bold", "EmailStrong"}, {"it", "EmailEmph"}, {"co*de", "EmailCode"}, {"https://y.org", "EmailLink"}}
	if got := spansOn(d, 1); !slices.Equal(got, want) {
		t.Errorf("spans = %+v", got)
	}
	if d.Links[0].URL != "https://y.org" {
		t.Errorf("links = %+v", d.Links)
	}
}

func TestLinkedImagesShowAltTextAndRecordTheirRow(t *testing.T) {
	d := md([]string{"[![Logo](cid:logo@x)](https://x.com) and ![](data:image/png;base64,AA)", "after"}, 40, false)
	if !slices.Equal(d.Lines, []string{"L I Logo and I ", "", "after"}) {
		t.Fatalf("lines = %q", d.Lines)
	}
	want := []Image{{1, "Logo", "cid:logo@x"}, {2, "", "data:image/png;base64,AA"}}
	if !slices.Equal(d.Images, want) || d.Links[0].URL != "https://x.com" {
		t.Errorf("images = %+v links = %+v", d.Images, d.Links)
	}
}

func TestBlocksGetTheirIcons(t *testing.T) {
	d := md([]string{"# Title", "## Sub", "- one", "  - two", "> quoted", "---"}, 10, false)
	want := []string{"H1 Title", "H2 Sub", "* one", "  - two", "| quoted", strings.Repeat("─", 10)}
	if !slices.Equal(d.Lines, want) {
		t.Fatalf("lines = %q", d.Lines)
	}
	if !slices.Equal(d.LineHighlights, []LineHighlight{{1, "EmailH1Bg"}, {2, "EmailH2Bg"}}) {
		t.Errorf("line highlights = %+v", d.LineHighlights)
	}
}

func TestCodeBlocksKeepTheirText(t *testing.T) {
	d := md([]string{"```", "a **b** [c](d)", "```"}, 40, false)
	if !slices.Equal(d.Lines, []string{"a **b** [c](d)"}) || !slices.Equal(d.LineHighlights, []LineHighlight{{1, "EmailCodeBlock"}}) {
		t.Errorf("doc = %+v", d)
	}
}

func TestTablesBecomeBoxTables(t *testing.T) {
	d := md([]string{"| Name | Qty |", "| - | -: |", "| Apples | 3 |", "| [Pear](https://p.ex) | 12 |"}, 40, false)
	want := []string{
		"┌────────┬─────┐",
		"│ Name   │ Qty │",
		"├────────┼─────┤",
		"│ Apples │   3 │",
		"│ L Pear │  12 │",
		"└────────┴─────┘",
	}
	if !slices.Equal(d.Lines, want) {
		t.Fatalf("lines =\n%s", strings.Join(d.Lines, "\n"))
	}
	if !slices.Equal(d.Links, []Link{{5, len("│ "), len("│ L Pear"), "https://p.ex"}}) {
		t.Errorf("links = %+v", d.Links)
	}
}

func TestWideTablesWrapInsideCells(t *testing.T) {
	d := md([]string{"| A | B |", "| - | - |", "| short | a long cell that needs wrapping |"}, 24, false)
	for _, line := range d.Lines {
		if Width(line) > 24 {
			t.Errorf("line %q is wider than 24", line)
		}
	}
	want := []string{"│ short │ a long cell  │", "│       │ that needs   │", "│       │ wrapping     │"}
	if !slices.Equal(d.Lines[3:6], want) {
		t.Errorf("rows =\n%s", strings.Join(d.Lines, "\n"))
	}
}

func TestPlainSegmentsStayAsTheyAre(t *testing.T) {
	d := Render([]Segment{{Lines: []string{"snake_case and 2 * 3 [x](y)"}}}, 40, opts)
	if !slices.Equal(d.Lines, []string{"snake_case and 2 * 3 [x](y)"}) || len(d.Links) != 0 {
		t.Errorf("doc = %+v", d)
	}
}

func TestReplyModeKeepsURLsInline(t *testing.T) {
	d := md([]string{"Go to [site](https://s.ex) or https://t.ex"}, 40, true)
	if !slices.Equal(d.Lines, []string{"Go to site <https://s.ex> or https://t.ex"}) {
		t.Errorf("lines = %q", d.Lines)
	}
}

func TestSegmentsAreSeparatedAndLinesTrimmed(t *testing.T) {
	if got := Lines("\r\n\n a\r\nb \n\n"); !slices.Equal(got, []string{" a", "b "}) {
		t.Errorf("Lines = %q", got)
	}
	d := Render([]Segment{{Lines: []string{"x"}}, {Lines: []string{"y"}, Markdown: true}}, 40, opts)
	if !slices.Equal(d.Lines, []string{"x", "", "y"}) {
		t.Errorf("lines = %q", d.Lines)
	}
}

func TestHighlightsEncodeAsArrays(t *testing.T) {
	b, _ := Highlight{1, 2, 3, `Em"ph`}.MarshalJSON()
	l, _ := LineHighlight{4, "G"}.MarshalJSON()
	if string(b) != `[1,2,3,"Em\"ph"]` || string(l) != `[4,"G"]` {
		t.Errorf("%s %s", b, l)
	}
}

func TestWidthCountsCells(t *testing.T) {
	for s, want := range map[string]int{"abc": 3, "æøå": 3, "日本": 4, "\u200b": 0} {
		if got := Width(s); got != want {
			t.Errorf("Width(%q) = %d, want %d", s, got, want)
		}
	}
}
