package rpc

import (
	"bufio"
	"encoding/json"
	"io"
	"strings"
	"testing"

	"github.com/stubbedev/email.nvim/engine/internal/mailtest"
)

func TestServeAnswersEveryRequestByID(t *testing.T) {
	mailtest.Setup(t, map[string]string{
		"INBOX/new/1": mailtest.Message("a@example.org", "Ann <ann@example.org>", "me@example.com", "Hi", "Thu, 19 Nov 2026 10:00:00 +0000", "hello"),
	})
	requests := strings.Join([]string{
		`{"id":1,"method":"hello"}`,
		`{"id":2,"method":"threads","params":{"query":"*","limit":5}}`,
		`{"id":3,"method":"configure","params":{"accounts":[{"name":"A","maildir":"acct","from":"Me <me@example.com>","addresses":["me@example.com"],"inbox":"INBOX","sent":"Sent","drafts":"Drafts"}]}}`,
	}, "\n") + "\n"
	in, feed := io.Pipe()
	out, results := io.Pipe()
	go func() {
		_ = Serve(t.Context(), "test", in, results)
		_ = results.Close()
	}()
	responses := map[int64]response{}
	scanner := bufio.NewScanner(out)
	send := func(lines string) {
		if _, err := feed.Write([]byte(lines)); err != nil {
			t.Fatal(err)
		}
	}
	read := func(n int) {
		for range n {
			if !scanner.Scan() {
				t.Fatalf("server closed early: %v", scanner.Err())
			}
			var r response
			if err := json.Unmarshal(scanner.Bytes(), &r); err != nil {
				t.Fatal(err)
			}
			responses[r.ID] = r
		}
	}
	send(requests)
	read(3)
	send(`{"id":4,"method":"threads","params":{"query":"*","limit":5,"count":true}}` + "\n" +
		`{"id":5,"method":"nope"}` + "\n" +
		`{"id":6,"method":"threads","params":{"query":"*","bogus":1}}` + "\n")
	read(3)
	_ = feed.Close()
	if responses[1].Error != "" || responses[1].Result.(map[string]any)["version"] != "test" {
		t.Errorf("hello = %+v", responses[1])
	}
	if !strings.Contains(responses[2].Error, "not configured") {
		t.Errorf("threads before configure = %+v", responses[2])
	}
	if responses[3].Error != "" {
		t.Errorf("configure = %+v", responses[3])
	}
	page, _ := responses[4].Result.(map[string]any)
	if responses[4].Error != "" || page["total"] != float64(1) {
		t.Errorf("threads = %+v", responses[4])
	}
	if responses[5].Error != "nope: unknown method" {
		t.Errorf("unknown = %+v", responses[5])
	}
	if !strings.Contains(responses[6].Error, "unknown field") {
		t.Errorf("unknown field = %+v", responses[6])
	}
}
