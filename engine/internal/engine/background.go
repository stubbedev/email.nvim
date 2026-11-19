package engine

import (
	"fmt"
	"os"
	"sync"
	"time"
)

const quietBeforeBackground = 50 * time.Millisecond

type job struct {
	name string
	run  func() error
}

type background struct {
	mu      sync.Mutex
	cond    *sync.Cond
	active  int
	last    time.Time
	warm    []job
	fetch   []job
	started bool
}

func (b *background) init() {
	if b.cond == nil {
		b.cond = sync.NewCond(&b.mu)
	}
}

func (b *background) begin() {
	b.mu.Lock()
	b.init()
	b.active++
	b.mu.Unlock()
}

func (b *background) end() {
	b.mu.Lock()
	b.active--
	b.last = time.Now()
	b.cond.Broadcast()
	b.mu.Unlock()
}

func (b *background) schedule(replaceWarm bool, jobs []job) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.init()
	if replaceWarm {
		b.warm = jobs
	} else {
		b.fetch = append(b.fetch, jobs...)
	}
	if !b.started {
		b.started = true
		go b.work()
	}
	b.cond.Broadcast()
}

func (b *background) next() job {
	b.mu.Lock()
	defer b.mu.Unlock()
	for {
		switch {
		case len(b.warm) == 0 && len(b.fetch) == 0, b.active > 0:
			b.cond.Wait()
		case time.Since(b.last) < quietBeforeBackground:
			wait := quietBeforeBackground - time.Since(b.last)
			b.mu.Unlock()
			time.Sleep(wait)
			b.mu.Lock()
		case len(b.warm) > 0:
			j := b.warm[0]
			b.warm = b.warm[1:]
			return j
		default:
			j := b.fetch[0]
			b.fetch = b.fetch[1:]
			return j
		}
	}
}

func (b *background) work() {
	for {
		j := b.next()
		if err := j.run(); err != nil {
			fmt.Fprintf(os.Stderr, "email-engine: %s: %v\n", j.name, err)
		}
	}
}

func (e *Engine) Begin() { e.jobs.begin() }

func (e *Engine) End() { e.jobs.end() }
