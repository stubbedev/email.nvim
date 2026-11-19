package engine

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"net/mail"
	"os"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/stubbedev/email.nvim/engine/internal/compose"
	"github.com/stubbedev/email.nvim/engine/internal/doc"
	"github.com/stubbedev/email.nvim/engine/internal/message"
	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
	"github.com/stubbedev/email.nvim/engine/internal/view"
)

type ThreadSummary struct {
	ID         string   `json:"id"`
	Timestamp  int64    `json:"timestamp"`
	Total      int      `json:"total"`
	Authors    string   `json:"authors"`
	Subject    string   `json:"subject"`
	Tags       []string `json:"tags"`
	MessageIDs []string `json:"message_ids"`
}

type ThreadPage struct {
	Total     *int            `json:"total,omitempty"`
	Threads   []ThreadSummary `json:"threads,omitempty"`
	Revision  string          `json:"revision"`
	Unchanged bool            `json:"unchanged,omitempty"`
}

type MessageView struct {
	ID          string          `json:"id"`
	Timestamp   int64           `json:"timestamp"`
	Tags        []string        `json:"tags"`
	Files       []string        `json:"files"`
	Accounts    []int           `json:"accounts"`
	Sender      string          `json:"sender"`
	HeaderLines []string        `json:"header_lines"`
	Doc         *doc.Doc        `json:"-"`
	DocJSON     json.RawMessage `json:"doc,omitempty"`
	view.View
}

func revisionOf(db *notmuch.Database) string {
	revision, uuid := db.Revision()
	return uuid + ":" + strconv.FormatUint(revision, 10)
}

func (e *Engine) Revision() (string, error) {
	var out string
	err := e.read(func(db *notmuch.Database) error {
		out = revisionOf(db)
		return nil
	})
	return out, err
}

func (e *Engine) Counts(queries []string) ([]int, error) {
	out := make([]int, len(queries))
	err := e.read(func(db *notmuch.Database) error {
		key := revisionOf(db)
		for i, q := range queries {
			if value, ok := e.cache.get("messages\x00"+q, key); ok {
				out[i] = value.(int)
				continue
			}
			n, err := db.CountMessages(q)
			if err != nil {
				return err
			}
			e.cache.put("messages\x00"+q, key, n)
			out[i] = n
		}
		return nil
	})
	return out, err
}

func (e *Engine) NewestMessage(thread, query string) (string, error) {
	var id string
	err := e.read(func(db *notmuch.Database) error {
		q := fmt.Sprintf("thread:%s and (%s)", thread, query)
		found, err := db.Messages(q, notmuch.NewestFirst, 1)
		if err != nil {
			return err
		}
		if len(found) == 0 {
			return fmt.Errorf("thread %s has no message matching %s", thread, query)
		}
		id = found[0].ID
		return nil
	})
	return id, err
}

func load(m notmuch.Message) (*message.Message, error) {
	var errs []error
	for _, file := range m.Files {
		raw, err := os.ReadFile(file) //nolint:gosec
		if err != nil {
			errs = append(errs, err)
			continue
		}
		parsed, err := message.Parse(raw)
		if err != nil {
			return nil, fmt.Errorf("message %s (%s): %w", m.ID, file, err)
		}
		return parsed, nil
	}
	return nil, fmt.Errorf("message %s: no readable file: %w", m.ID, errors.Join(errs...))
}

func (e *Engine) viewOf(m notmuch.Message, opts view.Options, r *Render) (MessageView, error) {
	accounts := []int{}
	for _, account := range e.owners(m.Files) {
		accounts = append(accounts, account.Number)
	}
	key := ""
	if len(m.Files) > 0 {
		key = viewKey(m.Files[0], opts, r)
	}
	entry, ok := e.views.get(key)
	if !ok {
		parsed, err := load(m)
		if err != nil {
			return MessageView{}, err
		}
		if entry, err = e.render(parsed, opts, r); err != nil {
			return MessageView{}, err
		}
		e.views.put(key, entry)
	}
	v := MessageView{
		ID: m.ID, Timestamp: m.Date, Tags: m.Tags, Files: m.Files, Accounts: accounts,
		Sender: entry.sender, HeaderLines: entry.headerLines, Doc: entry.doc, DocJSON: entry.docJSON, View: entry.view,
	}
	if v.Doc != nil {
		v.Blocks = nil
	}
	return v, nil
}

func (e *Engine) render(parsed *message.Message, opts view.Options, r *Render) (renderedView, error) {
	entry := renderedView{sender: "(unknown)", view: view.Build(parsed, opts)}
	if from := parsed.Addresses("From"); len(from) > 0 {
		entry.sender = cmp.Or(from[0].Name, from[0].Address)
	}
	entry.headerLines = headerLines(entry.view.Headers)
	if r != nil && e.renderable(entry.view.Blocks) {
		rendered, err := e.layout(entry.view.Blocks, *r)
		if err != nil {
			return renderedView{}, err
		}
		entry.doc = &rendered
		if entry.docJSON, err = json.Marshal(rendered); err != nil {
			return renderedView{}, fmt.Errorf("encoding the rendered message: %w", err)
		}
	}
	entry.size = sizeOf(entry.view, entry.doc)
	return entry, nil
}

func (e *Engine) options(alternatives []string) view.Options {
	opts := e.view
	if len(alternatives) > 0 {
		opts.Alternatives = alternatives
	}
	return opts
}

func (e *Engine) open(id string) (notmuch.Message, *message.Message, error) {
	var m notmuch.Message
	var parsed *message.Message
	err := e.read(func(db *notmuch.Database) error {
		var err error
		if m, err = db.Message(id); err != nil {
			return err
		}
		parsed, err = load(m)
		return err
	})
	return m, parsed, err
}

func (e *Engine) Message(id string, alternatives []string, r *Render) (MessageView, error) {
	var v MessageView
	err := e.read(func(db *notmuch.Database) error {
		m, err := db.Message(id)
		if err != nil {
			return err
		}
		v, err = e.viewOf(m, e.options(alternatives), r)
		return err
	})
	return v, err
}

func (e *Engine) Warm(ids []string, r *Render) {
	jobs := make([]job, len(ids))
	for i, id := range ids {
		jobs[i] = job{name: "warming thread " + id, run: func() error {
			_, err := e.thread(id, r, 1)
			return err
		}}
	}
	e.jobs.schedule(true, jobs)
}

func (e *Engine) Thread(id string, r *Render) ([]MessageView, error) {
	return e.thread(id, r, runtime.GOMAXPROCS(0))
}

func (e *Engine) thread(id string, r *Render, workers int) ([]MessageView, error) {
	var views []MessageView
	err := e.read(func(db *notmuch.Database) error {
		key, revision := "thread\x00"+id, revisionOf(db)
		var messages []notmuch.Message
		if value, ok := e.cache.get(key, revision); ok {
			messages = value.([]notmuch.Message)
		} else {
			var err error
			if messages, err = db.Messages("thread:"+id, notmuch.OldestFirst, 0); err != nil {
				return err
			}
			e.cache.put(key, revision, messages)
		}
		if len(messages) == 0 {
			return fmt.Errorf("thread %s has no messages", id)
		}
		views = make([]MessageView, len(messages))
		errs := make([]error, len(messages))
		jobs := make(chan int)
		var wg sync.WaitGroup
		for range min(workers, len(messages)) {
			wg.Go(func() {
				for i := range jobs {
					views[i], errs[i] = e.viewOf(messages[i], e.view, r)
				}
			})
		}
		for i := range messages {
			jobs <- i
		}
		close(jobs)
		wg.Wait()
		return errors.Join(errs...)
	})
	if err != nil {
		return nil, err
	}
	return views, nil
}

func (e *Engine) Part(id string, number int) (*message.Part, error) {
	_, parsed, err := e.open(id)
	if err != nil {
		return nil, err
	}
	part := parsed.Find(number)
	if part == nil {
		return nil, fmt.Errorf("message %s has no part %d", id, number)
	}
	if strings.HasPrefix(part.ContentType, "multipart/") {
		return nil, fmt.Errorf("part %d of message %s is a %s container, not a file", number, id, part.ContentType)
	}
	return part, nil
}

func (e *Engine) Extract(id string, number int, path string) (int, error) {
	part, err := e.Part(id, number)
	if err != nil {
		return 0, err
	}
	if err := writeAtomic(path, part.Body); err != nil {
		return 0, err
	}
	return len(part.Body), nil
}

type ReplyHeaders struct {
	From       string `json:"from"`
	To         string `json:"to"`
	Cc         string `json:"cc"`
	Subject    string `json:"subject"`
	InReplyTo  string `json:"in_reply_to"`
	References string `json:"references"`
	Account    int    `json:"account"`
	Name       string `json:"name"`
	Address    string `json:"address"`
}

func (e *Engine) Reply(id string, all bool, preferred int) (ReplyHeaders, error) {
	if len(e.accounts) == 0 {
		return ReplyHeaders{}, errNoAccounts
	}
	m, parsed, err := e.open(id)
	if err != nil {
		return ReplyHeaders{}, err
	}
	reply := compose.BuildReply(parsed, e.accounts, all)
	var account *Account
	from := *(e.accounts[0].From)
	if reply.Recipient != "" {
		if account, err = e.accountFor(reply.Recipient); err != nil {
			return ReplyHeaders{}, err
		}
		from.Name, from.Address = account.From.Name, reply.Recipient
	} else if account, err = e.owner(id, m.Files, preferred); err == nil {
		from = *account.From
	} else {
		account = e.accounts[0]
	}
	return ReplyHeaders{
		From:       compose.Display(&from),
		To:         compose.DisplayList(reply.To),
		Cc:         compose.DisplayList(reply.Cc),
		Subject:    reply.Subject,
		InReplyTo:  reply.InReplyTo,
		References: reply.References,
		Account:    account.Number,
		Name:       from.Name,
		Address:    from.Address,
	}, nil
}

type RankedAddress struct {
	Address string `json:"addr"`
	Name    string `json:"name,omitempty"`
	Display string `json:"display"`
	Score   int    `json:"score"`
}

const sentWeight = 10

func (e *Engine) Addresses() ([]RankedAddress, error) {
	var mine []string
	for _, account := range e.accounts {
		for address := range account.addresses {
			mine = append(mine, "from:"+address)
		}
	}
	slices.Sort(mine)
	ranked := map[string]*RankedAddress{}
	add := func(values []string, weight int) {
		for _, value := range values {
			for _, address := range message.ParseAddresses(value) {
				key := strings.ToLower(address.Address)
				entry := ranked[key]
				if entry == nil {
					entry = &RankedAddress{Address: address.Address}
					ranked[key] = entry
				}
				entry.Score += weight
				if entry.Name == "" {
					entry.Name = address.Name
				}
			}
		}
	}
	err := e.read(func(db *notmuch.Database) error {
		if len(mine) > 0 {
			sent := strings.Join(mine, " or ")
			for _, header := range []string{"to", "cc", "bcc"} {
				values, err := db.Headers(sent, header)
				if err != nil {
					return err
				}
				add(values, sentWeight)
			}
		}
		senders, err := db.Headers("*", "from")
		if err != nil {
			return err
		}
		add(senders, 1)
		return nil
	})
	if err != nil {
		return nil, err
	}
	out := make([]RankedAddress, 0, len(ranked))
	for _, entry := range ranked {
		entry.Display = compose.Display(&mail.Address{Name: entry.Name, Address: entry.Address})
		out = append(out, *entry)
	}
	slices.SortFunc(out, func(a, b RankedAddress) int {
		return cmp.Or(cmp.Compare(b.Score, a.Score), cmp.Compare(strings.ToLower(a.Address), strings.ToLower(b.Address)))
	})
	return out, nil
}
