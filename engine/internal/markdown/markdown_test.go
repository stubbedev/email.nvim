package markdown

import "testing"

func TestToHTML(t *testing.T) {
	for _, tt := range []struct{ name, in, want string }{
		{"hard_breaks", "line one\nline two\n", "<p>line one<br>\nline two</p>\n"},
		{"emphasis", "**bold** and *it*\n", "<p><strong>bold</strong> and <em>it</em></p>\n"},
		{"quote", "> quoted\n", "<blockquote>\n<p>quoted</p>\n</blockquote>\n"},
		{"autolink", "see https://x.com/a\n", "<p>see <a href=\"https://x.com/a\">https://x.com/a</a></p>\n"},
		{"strikethrough", "~~gone~~\n", "<p><del>gone</del></p>\n"},
		{"table", "| a | b |\n| - | - |\n| 1 | 2 |\n", "<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</tbody>\n</table>\n"},
		{"raw_html_escaped", "<script>x()</script>\n", "<!-- raw HTML omitted -->\n"},
		{"signature", "Hi\n\n-- \nAlex\n", "<p>Hi</p>\n<p>--<br>\nAlex</p>\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ToHTML(tt.in)
			if err != nil || got != tt.want {
				t.Errorf("ToHTML(%q) = %q, %v\nwant %q", tt.in, got, err, tt.want)
			}
		})
	}
}
