package smtp

import (
	"strings"
	"testing"

	"github.com/stubbedev/email.nvim/engine/internal/smtp/smtptest"
)

func TestSendWithLoginAuth(t *testing.T) {
	fake := smtptest.Start(t, "LOGIN")
	server := Server{Host: "127.0.0.1", Port: fake.Port, Security: None, User: "me", Password: "secret"}
	if err := Send(t.Context(), server, "me@x.y", []string{"a@x.y", "b@x.y"}, []byte("Subject: hi\n\nbody\n")); err != nil {
		t.Fatal(err)
	}
	log := fake.Log()
	for _, want := range []string{"LOGIN me secret", "MAIL FROM:<me@x.y>", "RCPT TO:<a@x.y>", "RCPT TO:<b@x.y>"} {
		if !strings.Contains(log, want) {
			t.Errorf("session lacks %q:\n%s", want, log)
		}
	}
	if got := fake.Messages(); len(got) != 1 || got[0] != "Subject: hi\r\n\r\nbody\r\n" {
		t.Errorf("data = %q", got)
	}
}

func TestSendRefusesWithoutRecipients(t *testing.T) {
	if err := Send(t.Context(), Server{Host: "127.0.0.1", Port: 1}, "me@x.y", nil, nil); err == nil {
		t.Fatal("expected an error")
	}
}

func TestUnsupportedAuthIsAnError(t *testing.T) {
	fake := smtptest.Start(t, "XOAUTH2")
	err := Send(t.Context(), Server{Host: "127.0.0.1", Port: fake.Port, Security: None, User: "me", Password: "x"}, "me@x.y", []string{"a@x.y"}, []byte("x\n"))
	if err == nil || !strings.Contains(err.Error(), "no supported AUTH mechanism") {
		t.Errorf("err = %v", err)
	}
}
