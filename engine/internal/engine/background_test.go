package engine

import (
	"sync/atomic"
	"testing"
	"time"
)

func TestBackgroundWorkYieldsToInteractiveRequests(t *testing.T) {
	var b background
	var ran atomic.Int32
	done := make(chan time.Time, 4)
	record := func(n int32) job {
		return job{name: "test", run: func() error {
			ran.Add(n)
			done <- time.Now()
			return nil
		}}
	}
	b.begin()
	b.schedule(true, []job{record(1)})
	b.schedule(true, []job{record(10)})
	time.Sleep(3 * quietBeforeBackground)
	if ran.Load() != 0 {
		t.Fatal("background work ran during an interactive request")
	}
	b.end()
	released := time.Now()
	select {
	case at := <-done:
		if waited := at.Sub(released); waited < quietBeforeBackground {
			t.Errorf("background work started %v after the last request, want at least %v", waited, quietBeforeBackground)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("background work never ran")
	}
	time.Sleep(2 * quietBeforeBackground)
	if got := ran.Load(); got != 10 {
		t.Errorf("ran %d, want only the newer warm job (10)", got)
	}
}
