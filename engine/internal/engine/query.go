package engine

import (
	"fmt"

	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
)

type Output string

const (
	Messages Output = "messages"
	Threads  Output = "threads"
	Files    Output = "files"
)

func (e *Engine) Matching(query string, limit int, entireThread bool, alternatives []string) ([]MessageView, error) {
	opts := e.options(alternatives)
	var views []MessageView
	err := e.read(func(db *notmuch.Database) error {
		found, err := e.matching(db, query, limit, entireThread)
		if err != nil {
			return err
		}
		views = make([]MessageView, 0, len(found))
		for _, m := range found {
			v, err := e.viewOf(m, opts)
			if err != nil {
				return err
			}
			views = append(views, v)
		}
		return nil
	})
	return views, err
}

func (e *Engine) matching(db *notmuch.Database, query string, limit int, entireThread bool) ([]notmuch.Message, error) {
	matched, err := db.Messages(query, notmuch.NewestFirst, limit)
	if err != nil || !entireThread {
		return matched, err
	}
	var found []notmuch.Message
	seen := map[string]bool{}
	for _, m := range matched {
		if seen[m.ThreadID] {
			continue
		}
		seen[m.ThreadID] = true
		thread, err := db.Messages("thread:"+m.ThreadID, notmuch.OldestFirst, 0)
		if err != nil {
			return nil, err
		}
		found = append(found, thread...)
		if limit > 0 && len(found) >= limit {
			return found[:limit], nil
		}
	}
	return found, nil
}

func (e *Engine) Count(query string, output Output) (int, error) {
	var n int
	err := e.read(func(db *notmuch.Database) error {
		var err error
		switch output {
		case Messages:
			n, err = db.CountMessages(query)
		case Threads:
			n, err = db.CountThreads(query)
		case Files:
			var found []notmuch.Message
			found, err = db.Messages(query, notmuch.NewestFirst, 0)
			for _, m := range found {
				n += len(m.Files)
			}
		default:
			err = fmt.Errorf("output must be messages, threads or files, got %q", output)
		}
		return err
	})
	return n, err
}

func (e *Engine) Tags(query string) ([]string, error) {
	var tags []string
	err := e.read(func(db *notmuch.Database) error {
		var err error
		if query == "*" {
			tags = db.AllTags()
			return nil
		}
		tags, err = db.Tags(query)
		return err
	})
	return tags, err
}

func (e *Engine) TagMatching(query string, changes []string) (int, error) {
	parsed, err := notmuch.ParseTagChanges(changes)
	if err != nil {
		return 0, err
	}
	var n int
	err = e.write(func(db *notmuch.Database) error {
		found, err := db.Messages(query, notmuch.NewestFirst, 0)
		if err != nil {
			return err
		}
		ids := make([]string, len(found))
		for i, m := range found {
			ids[i] = m.ID
		}
		n = len(ids)
		return db.Tag(ids, parsed)
	})
	return n, err
}
