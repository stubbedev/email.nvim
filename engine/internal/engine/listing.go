package engine

import (
	"errors"
	"fmt"
	"sync"

	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
)

const cacheLimit = 256

type cache struct {
	mu      sync.Mutex
	entries map[string]cached
}

type cached struct {
	revision string
	value    any
}

func (c *cache) get(key, revision string) (any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[key]
	if !ok || entry.revision != revision {
		return nil, false
	}
	return entry.value, true
}

func (c *cache) put(key, revision string, value any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil || len(c.entries) >= cacheLimit {
		c.entries = make(map[string]cached, cacheLimit)
	}
	c.entries[key] = cached{revision: revision, value: value}
}

type listing struct {
	db       *notmuch.Database
	it       *notmuch.ThreadIter
	query    string
	sort     notmuch.Sort
	next     int
	revision string
}

func (l *listing) close() error {
	l.it.Close()
	return l.db.Close()
}

type cursor struct {
	mu sync.Mutex
	l  *listing
}

func (c *cursor) page(query string, sort notmuch.Sort, offset, limit int, revision string) ([]notmuch.Thread, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	l := c.l
	if l == nil || l.query != query || l.sort != sort || l.next != offset || l.revision != revision {
		if l != nil {
			c.l = nil
			if err := l.close(); err != nil {
				return nil, err
			}
		}
		db, err := notmuch.Open(notmuch.ReadOnly)
		if err != nil {
			return nil, err
		}
		it, err := db.ThreadIter(query, sort)
		if err != nil {
			return nil, errors.Join(err, db.Close())
		}
		it.Skip(offset)
		l = &listing{db: db, it: it, query: query, sort: sort, next: offset, revision: revision}
		c.l = l
	}
	threads, err := l.it.Next(limit)
	if err != nil {
		c.l = nil
		return nil, errors.Join(err, l.close())
	}
	l.next += len(threads)
	return threads, nil
}

func summaries(threads []notmuch.Thread) []ThreadSummary {
	out := make([]ThreadSummary, len(threads))
	for i, t := range threads {
		out[i] = ThreadSummary{
			ID: t.ID, Timestamp: t.Newest, Total: t.Total, Authors: t.Authors,
			Subject: t.Subject, Tags: t.Tags, MessageIDs: t.MatchedIDs,
		}
	}
	return out
}

func pageKey(query string, sort notmuch.Sort, limit int) string {
	return fmt.Sprintf("page\x00%d\x00%d\x00%s", sort, limit, query)
}

func countKey(query string) string { return "count\x00" + query }

func (e *Engine) CountThreads(query string) (int, error) {
	revision, err := e.Revision()
	if err != nil {
		return 0, err
	}
	if value, ok := e.cache.get(countKey(query), revision); ok {
		return value.(int), nil
	}
	var n int
	err = e.read(func(db *notmuch.Database) error {
		n, err = db.CountThreads(query)
		return err
	})
	if err != nil {
		return 0, err
	}
	e.cache.put(countKey(query), revision, n)
	return n, nil
}

func (e *Engine) Threads(query string, sort notmuch.Sort, offset, limit int, count bool, known string) (ThreadPage, error) {
	page := ThreadPage{}
	if count {
		total, err := e.CountThreads(query)
		if err != nil {
			return page, err
		}
		page.Total = &total
	}
	revision, err := e.Revision()
	if err != nil {
		return page, err
	}
	page.Revision = revision
	if offset == 0 && known == revision {
		page.Unchanged = true
		return page, nil
	}
	if offset == 0 {
		if value, ok := e.cache.get(pageKey(query, sort, limit), revision); ok {
			page.Threads = value.([]ThreadSummary)
			return page, nil
		}
	}
	threads, err := e.cursor.page(query, sort, offset, limit, revision)
	if err != nil {
		return page, err
	}
	page.Threads = summaries(threads)
	if offset == 0 {
		e.cache.put(pageKey(query, sort, limit), revision, page.Threads)
	}
	return page, nil
}

func (e *Engine) warm(query string, limit int) error {
	if _, err := e.CountThreads(query); err != nil {
		return err
	}
	revision, err := e.Revision()
	if err != nil {
		return err
	}
	key := pageKey(query, notmuch.NewestFirst, limit)
	if _, ok := e.cache.get(key, revision); ok {
		return nil
	}
	var threads []notmuch.Thread
	err = e.read(func(db *notmuch.Database) error {
		threads, err = db.Threads(query, notmuch.NewestFirst, 0, limit)
		return err
	})
	if err != nil {
		return err
	}
	e.cache.put(key, revision, summaries(threads))
	return nil
}

func (e *Engine) Prefetch(queries []string, limit int) <-chan struct{} {
	done := make(chan struct{})
	jobs := make([]job, 0, len(queries)+1)
	for _, query := range queries {
		jobs = append(jobs, job{name: fmt.Sprintf("prefetching %q", query), run: func() error { return e.warm(query, limit) }})
	}
	jobs = append(jobs, job{name: "prefetch", run: func() error {
		close(done)
		return nil
	}})
	e.jobs.schedule(false, jobs)
	return done
}
