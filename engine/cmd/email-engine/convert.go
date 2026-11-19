package main

import (
	"fmt"
	"io"

	"github.com/stubbedev/email.nvim/engine/internal/calendar"
	"github.com/stubbedev/email.nvim/engine/internal/convert"
	"github.com/stubbedev/email.nvim/engine/internal/markdown"
	"github.com/stubbedev/email.nvim/engine/internal/plain"
)

const convertUsage = `usage: email-engine convert [--html [--images] | --plain [--flowed] | --calendar]
       email-engine convert --to-html

  --html      force the HTML pipeline (vendor-noisy HTML → Markdown)
  --images    keep content images as ![alt](src) (cid:, data:image and http(s)
              sources; tracking pixels and spacers are still dropped)
  --plain     a text/plain part, passed through
  --flowed    with --plain: the part is format=flowed (RFC 3676), so dewrap it
  --calendar  render an iCalendar part (invites, todos)
  (no flag)   auto-detect: BEGIN:VCALENDAR → calendar, HTML markers → html, else plain
  --to-html   the reverse: render Markdown (an outgoing message body) as an HTML
              fragment, keeping line breaks; raw HTML in the input is left out
`

func runConvert(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	var mode convert.Format
	var opts convert.Options
	haveMode, toHTML, flowed := false, false, false
	for _, arg := range args {
		switch arg {
		case "--html":
			mode, haveMode = convert.Html, true
		case "--plain":
			mode, haveMode = convert.Plain, true
		case "--calendar":
			mode, haveMode = convert.Calendar, true
		case "--images":
			opts.Images = true
		case "--to-html":
			toHTML = true
		case "--flowed":
			flowed = true
		case "-h", "--help":
			_, _ = fmt.Fprint(stdout, convertUsage)
			return 0
		default:
			_, _ = fmt.Fprintf(stderr, "email-engine convert: unknown argument `%s`\n\n%s", arg, convertUsage)
			return 2
		}
	}
	raw, err := io.ReadAll(stdin)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "email-engine convert: reading stdin: %v\n", err)
		return 1
	}
	input := string(raw)
	var out string
	switch {
	case toHTML && (haveMode || opts.Images || flowed):
		_, _ = fmt.Fprintf(stderr, "email-engine convert: --to-html takes no other flags\n\n%s", convertUsage)
		return 2
	case toHTML:
		out, err = markdown.ToHTML(input)
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "email-engine convert: %v\n", err)
			return 1
		}
	default:
		if !haveMode {
			mode = convert.Detect(input)
		}
		switch mode {
		case convert.Html:
			out = convert.Convert(input, opts)
		case convert.Plain:
			out = plain.Render(input, flowed)
		case convert.Calendar:
			out = calendar.Convert(input)
		}
	}
	if _, err := io.WriteString(stdout, out); err != nil {
		_, _ = fmt.Fprintf(stderr, "email-engine convert: writing stdout: %v\n", err)
		return 1
	}
	return 0
}
