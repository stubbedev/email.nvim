package smtp

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/smtp"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

type Security string

const (
	TLS      Security = "tls"
	StartTLS Security = "starttls"
	None     Security = "none"
)

type Mechanism string

const (
	Auto  Mechanism = ""
	Plain Mechanism = "plain"
	Login Mechanism = "login"
)

type Server struct {
	Host     string
	Port     int
	Security Security
	User     string
	Password string
	Auth     Mechanism
}

const (
	dialTimeout    = 30 * time.Second
	sessionTimeout = 5 * time.Minute
)

func (s Server) address() string { return net.JoinHostPort(s.Host, strconv.Itoa(s.Port)) }

func Send(ctx context.Context, server Server, from string, recipients []string, data []byte) error {
	if len(recipients) == 0 {
		return errors.New("smtp: the message has no recipients")
	}
	conn, err := dial(ctx, server)
	if err != nil {
		return err
	}
	if err := conn.SetDeadline(time.Now().Add(sessionTimeout)); err != nil {
		_ = conn.Close()
		return fmt.Errorf("smtp %s: setting deadline: %w", server.address(), err)
	}
	client, err := smtp.NewClient(conn, server.Host)
	if err != nil {
		_ = conn.Close()
		return fmt.Errorf("smtp %s: greeting: %w", server.address(), err)
	}
	defer func() { _ = client.Close() }()
	if err := session(client, server, from, recipients, data); err != nil {
		return fmt.Errorf("smtp %s: %w", server.address(), err)
	}
	return nil
}

func dial(ctx context.Context, server Server) (net.Conn, error) {
	dialer := &net.Dialer{Timeout: dialTimeout}
	if server.Security == TLS {
		conn, err := (&tls.Dialer{NetDialer: dialer, Config: &tls.Config{ServerName: server.Host, MinVersion: tls.VersionTLS12}}).DialContext(ctx, "tcp", server.address())
		if err != nil {
			return nil, fmt.Errorf("smtp %s: connecting over TLS: %w", server.address(), err)
		}
		return conn, nil
	}
	conn, err := dialer.DialContext(ctx, "tcp", server.address())
	if err != nil {
		return nil, fmt.Errorf("smtp %s: connecting: %w", server.address(), err)
	}
	return conn, nil
}

func session(client *smtp.Client, server Server, from string, recipients []string, data []byte) error {
	hostname, err := os.Hostname()
	if err != nil || hostname == "" {
		hostname = "localhost"
	}
	if err := client.Hello(hostname); err != nil {
		return fmt.Errorf("EHLO: %w", err)
	}
	if server.Security == StartTLS {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return errors.New("the server does not offer STARTTLS")
		}
		if err := client.StartTLS(&tls.Config{ServerName: server.Host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("STARTTLS: %w", err)
		}
	}
	if server.User != "" {
		auth, err := authFor(client, server)
		if err != nil {
			return err
		}
		if err := client.Auth(auth); err != nil {
			return fmt.Errorf("authenticating as %s: %w", server.User, err)
		}
	}
	if err := client.Mail(from); err != nil {
		return fmt.Errorf("MAIL FROM %s: %w", from, err)
	}
	for _, recipient := range recipients {
		if err := client.Rcpt(recipient); err != nil {
			return fmt.Errorf("RCPT TO %s: %w", recipient, err)
		}
	}
	w, err := client.Data()
	if err != nil {
		return fmt.Errorf("DATA: %w", err)
	}
	if _, err := w.Write(data); err != nil {
		_ = w.Close()
		return fmt.Errorf("writing the message: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("finishing the message: %w", err)
	}
	if err := client.Quit(); err != nil {
		return fmt.Errorf("QUIT: %w", err)
	}
	return nil
}

func authFor(client *smtp.Client, server Server) (smtp.Auth, error) {
	mechanism := server.Auth
	if mechanism == Auto {
		_, offered := client.Extension("AUTH")
		mechanisms := strings.Fields(strings.ToUpper(offered))
		switch {
		case slices.Contains(mechanisms, "PLAIN"):
			mechanism = Plain
		case slices.Contains(mechanisms, "LOGIN"):
			mechanism = Login
		default:
			return nil, fmt.Errorf("the server offers no supported AUTH mechanism (offered: %q)", offered)
		}
	}
	switch mechanism {
	case Plain:
		return smtp.PlainAuth("", server.User, server.Password, server.Host), nil
	case Login:
		return &loginAuth{user: server.User, password: server.Password, host: server.Host}, nil
	default:
		return nil, fmt.Errorf("unknown AUTH mechanism %q", mechanism)
	}
}

type loginAuth struct {
	user, password, host string
}

func (a *loginAuth) Start(info *smtp.ServerInfo) (string, []byte, error) {
	if !info.TLS && !isLocalhost(info.Name) {
		return "", nil, errors.New("refusing AUTH LOGIN over an unencrypted connection")
	}
	if info.Name != a.host {
		return "", nil, fmt.Errorf("AUTH LOGIN: connected to %s, expected %s", info.Name, a.host)
	}
	return "LOGIN", nil, nil
}

func (a *loginAuth) Next(challenge []byte, more bool) ([]byte, error) {
	if !more {
		return nil, nil
	}
	switch strings.ToLower(strings.TrimSpace(string(challenge))) {
	case "username:", "user name", "username":
		return []byte(a.user), nil
	case "password:", "password":
		return []byte(a.password), nil
	default:
		return nil, fmt.Errorf("AUTH LOGIN: unexpected challenge %q", challenge)
	}
}

func isLocalhost(name string) bool {
	return name == "localhost" || name == "127.0.0.1" || name == "::1"
}
