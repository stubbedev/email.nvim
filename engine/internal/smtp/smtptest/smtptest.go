package smtptest

import (
	"bufio"
	"encoding/base64"
	"net"
	"strings"
	"sync"
	"testing"
)

type Server struct {
	Port     int
	listener net.Listener
	auth     string
	mu       sync.Mutex
	log      []string
	data     []string
}

func Start(t *testing.T, auth string) *Server {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Port: l.Addr().(*net.TCPAddr).Port, listener: l, auth: auth}
	go s.accept()
	t.Cleanup(func() { _ = l.Close() })
	return s
}

func (s *Server) Log() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.log, "\n")
}

func (s *Server) Messages() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.data...)
}

func (s *Server) record(line string) {
	s.mu.Lock()
	s.log = append(s.log, line)
	s.mu.Unlock()
}

func (s *Server) accept() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		s.session(conn)
	}
}

func (s *Server) session(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	r := bufio.NewReader(conn)
	say := func(line string) { _, _ = conn.Write([]byte(line + "\r\n")) }
	read := func() string {
		line, _ := r.ReadString('\n')
		return strings.TrimRight(line, "\r\n")
	}
	say("220 fake ESMTP")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimRight(line, "\r\n")
		s.record(line)
		switch strings.ToUpper(strings.Fields(line + " x")[0]) {
		case "EHLO":
			say("250-fake")
			say("250 AUTH " + s.auth)
		case "AUTH":
			say("334 " + base64.StdEncoding.EncodeToString([]byte("Username:")))
			user, _ := base64.StdEncoding.DecodeString(read())
			say("334 " + base64.StdEncoding.EncodeToString([]byte("Password:")))
			pass, _ := base64.StdEncoding.DecodeString(read())
			s.record("LOGIN " + string(user) + " " + string(pass))
			say("235 ok")
		case "MAIL", "RCPT":
			say("250 ok")
		case "DATA":
			say("354 go")
			var body strings.Builder
			for {
				l, err := r.ReadString('\n')
				if err != nil || l == ".\r\n" {
					break
				}
				body.WriteString(l)
			}
			s.mu.Lock()
			s.data = append(s.data, body.String())
			s.mu.Unlock()
			say("250 queued")
		case "QUIT":
			say("221 bye")
			return
		default:
			say("502 no")
		}
	}
}
