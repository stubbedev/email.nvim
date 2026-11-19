package engine

import (
	"errors"
	"fmt"
	"net/mail"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"

	"github.com/stubbedev/email.nvim/engine/internal/doc"
	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
	"github.com/stubbedev/email.nvim/engine/internal/smtp"
	"github.com/stubbedev/email.nvim/engine/internal/view"
)

type SMTPConfig struct {
	Host        string         `json:"host"`
	Port        int            `json:"port"`
	Security    smtp.Security  `json:"security"`
	User        string         `json:"user"`
	PasswordCmd []string       `json:"password_cmd"`
	Auth        smtp.Mechanism `json:"auth"`
}

type AccountConfig struct {
	Name      string      `json:"name"`
	Maildir   string      `json:"maildir"`
	From      string      `json:"from"`
	Addresses []string    `json:"addresses"`
	Inbox     string      `json:"inbox"`
	Sent      string      `json:"sent"`
	Drafts    string      `json:"drafts"`
	Archive   string      `json:"archive"`
	Trash     string      `json:"trash"`
	SMTP      *SMTPConfig `json:"smtp"`
}

type Config struct {
	Accounts        []AccountConfig `json:"accounts"`
	Markdown        doc.Options     `json:"markdown"`
	Alternatives    []string        `json:"alternatives"`
	RawTypes        []string        `json:"raw_types"`
	Images          bool            `json:"images"`
	HTMLAlternative bool            `json:"html_alternative"`
}

type Account struct {
	Number    int
	Name      string
	Root      string
	From      *mail.Address
	addresses map[string]bool
	Inbox     string
	Sent      string
	Drafts    string
	Archive   string
	Trash     string
	SMTP      *SMTPConfig
}

func (a *Account) Owns(address string) bool { return a.addresses[strings.ToLower(address)] }

func (a *Account) holds(files []string) bool {
	for _, file := range files {
		if rel, err := filepath.Rel(a.Root, file); err == nil && !strings.HasPrefix(rel, "..") {
			return true
		}
	}
	return false
}

type identities []*Account

func (ids identities) Owns(address string) bool {
	for _, account := range ids {
		if account.Owns(address) {
			return true
		}
	}
	return false
}

type Engine struct {
	accounts identities
	view     view.Options
	html     bool
	markdown doc.Options
	mu       sync.RWMutex
	cache    cache
	cursor   cursor
	views    viewCache
	readers  chan *notmuch.Database
}

func New(cfg Config) (*Engine, error) {
	e := &Engine{
		readers:  make(chan *notmuch.Database, runtime.GOMAXPROCS(0)),
		view:     view.Options{Alternatives: cfg.Alternatives, Raw: map[string]bool{}, Images: cfg.Images},
		html:     cfg.HTMLAlternative,
		markdown: cfg.Markdown,
	}
	if len(e.view.Alternatives) == 0 {
		e.view.Alternatives = []string{"text/html", "text/plain"}
	}
	for _, t := range cfg.RawTypes {
		e.view.Raw[strings.ToLower(t)] = true
	}
	if len(cfg.Accounts) == 0 {
		return e, nil
	}
	var root string
	err := e.read(func(db *notmuch.Database) error {
		root = db.MailRoot()
		return nil
	})
	if err != nil {
		return nil, err
	}
	if root == "" {
		return nil, errors.New("notmuch has no mail root (database.mail_root / database.path)")
	}
	for i, ac := range cfg.Accounts {
		account, err := newAccount(i+1, ac, root)
		if err != nil {
			return nil, fmt.Errorf("accounts[%d] (%s): %w", i+1, ac.Name, err)
		}
		e.accounts = append(e.accounts, account)
	}
	return e, nil
}

func newAccount(number int, ac AccountConfig, root string) (*Account, error) {
	for _, field := range []struct{ name, value string }{
		{"name", ac.Name}, {"maildir", ac.Maildir}, {"from", ac.From}, {"inbox", ac.Inbox}, {"sent", ac.Sent}, {"drafts", ac.Drafts},
	} {
		if field.value == "" {
			return nil, fmt.Errorf("%s is required", field.name)
		}
	}
	from, err := mail.ParseAddress(ac.From)
	if err != nil {
		return nil, fmt.Errorf("from %q: %w", ac.From, err)
	}
	if len(ac.Addresses) == 0 {
		return nil, errors.New("addresses must list at least one address")
	}
	account := &Account{
		Number:    number,
		Name:      ac.Name,
		Root:      filepath.Join(root, filepath.FromSlash(ac.Maildir)),
		From:      from,
		addresses: make(map[string]bool, len(ac.Addresses)),
		Inbox:     ac.Inbox,
		Sent:      ac.Sent,
		Drafts:    ac.Drafts,
		Archive:   ac.Archive,
		Trash:     ac.Trash,
		SMTP:      ac.SMTP,
	}
	for _, address := range ac.Addresses {
		account.addresses[strings.ToLower(address)] = true
	}
	if s := ac.SMTP; s != nil {
		if s.Host == "" || s.Port <= 0 {
			return nil, errors.New("smtp needs host and port")
		}
		if !slices.Contains([]smtp.Security{smtp.TLS, smtp.StartTLS, smtp.None}, s.Security) {
			return nil, fmt.Errorf("smtp.security must be tls, starttls or none, got %q", s.Security)
		}
		if !slices.Contains([]smtp.Mechanism{smtp.Auto, smtp.Plain, smtp.Login}, s.Auth) {
			return nil, fmt.Errorf("smtp.auth must be plain or login, got %q", s.Auth)
		}
		if (s.User == "") != (len(s.PasswordCmd) == 0) {
			return nil, errors.New("smtp.user and smtp.password_cmd go together")
		}
	}
	return account, nil
}

var errNoAccounts = errors.New("no accounts are configured")

func (e *Engine) reader() (*notmuch.Database, error) {
	select {
	case db := <-e.readers:
		if err := db.Reopen(); err == nil {
			return db, nil
		}
		_ = db.Close()
	default:
	}
	return notmuch.Open(notmuch.ReadOnly)
}

func (e *Engine) release(db *notmuch.Database) error {
	select {
	case e.readers <- db:
		return nil
	default:
		return db.Close()
	}
}

func (e *Engine) read(fn func(*notmuch.Database) error) error {
	e.mu.RLock()
	defer e.mu.RUnlock()
	db, err := e.reader()
	if err != nil {
		return err
	}
	return errors.Join(fn(db), e.release(db))
}

func (e *Engine) write(fn func(*notmuch.Database) error) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	db, err := notmuch.Open(notmuch.ReadWrite)
	if err != nil {
		return err
	}
	return errors.Join(fn(db), db.Close())
}

func (e *Engine) owners(files []string) []*Account {
	var out []*Account
	for _, account := range e.accounts {
		if account.holds(files) {
			out = append(out, account)
		}
	}
	return out
}

func (e *Engine) owner(id string, files []string, preferred int) (*Account, error) {
	owners := e.owners(files)
	for _, account := range owners {
		if account.Number == preferred {
			return account, nil
		}
	}
	if len(owners) == 0 {
		return nil, fmt.Errorf("message %s has no file in any configured account maildir", id)
	}
	return owners[0], nil
}

func (e *Engine) accountFor(address string) (*Account, error) {
	for _, account := range e.accounts {
		if account.Owns(address) {
			return account, nil
		}
	}
	return nil, fmt.Errorf("address %s belongs to no configured account", address)
}
