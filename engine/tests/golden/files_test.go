package golden

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stubbedev/email.nvim/engine/internal/convert"
)

var update = flag.Bool("update", false, "rewrite testdata/*.golden")

func TestGoldenFiles(t *testing.T) {
	inputs, err := filepath.Glob(filepath.Join("testdata", "*.html"))
	if err != nil || len(inputs) == 0 {
		t.Fatalf("no fixtures in testdata: %v", err)
	}
	root, err := os.OpenRoot("testdata")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = root.Close() }()
	for _, input := range inputs {
		name := filepath.Base(input)
		t.Run(name, func(t *testing.T) {
			raw, err := root.ReadFile(name)
			if err != nil {
				t.Fatal(err)
			}
			got := convert.Convert(string(raw), convert.Options{})
			golden := strings.TrimSuffix(name, ".html") + ".golden"
			if *update {
				if err := root.WriteFile(golden, []byte(got), 0o600); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := root.ReadFile(golden)
			if err != nil {
				t.Fatal(err)
			}
			if got != string(want) {
				t.Errorf("%s: rendered output differs from %s\n--- got ---\n%s\n--- want ---\n%s", name, golden, got, want)
			}
		})
	}
}
