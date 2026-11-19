package rpc

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/stubbedev/email.nvim/engine/internal/calendar"
	"github.com/stubbedev/email.nvim/engine/internal/doc"
	"github.com/stubbedev/email.nvim/engine/internal/engine"
	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
	"github.com/stubbedev/email.nvim/engine/internal/view"
)

type request struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type response struct {
	ID     int64  `json:"id"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

type server struct {
	version string
	mu      sync.RWMutex
	engine  *engine.Engine
}

type handler func(ctx context.Context, s *server, params json.RawMessage) (any, error)

func decode[T any](params json.RawMessage) (T, error) {
	var out T
	if len(params) == 0 {
		return out, nil
	}
	dec := json.NewDecoder(bytes.NewReader(params))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&out); err != nil {
		return out, fmt.Errorf("invalid params: %w", err)
	}
	return out, nil
}

func method[P any, R any](fn func(ctx context.Context, e *engine.Engine, p P) (R, error)) handler {
	return func(ctx context.Context, s *server, raw json.RawMessage) (any, error) {
		p, err := decode[P](raw)
		if err != nil {
			return nil, err
		}
		s.mu.RLock()
		e := s.engine
		s.mu.RUnlock()
		if e == nil {
			return nil, errors.New("the engine is not configured yet; call configure first")
		}
		return fn(ctx, e, p)
	}
}

type none struct{}

type idsParams struct {
	IDs       []string `json:"ids"`
	Preferred int      `json:"preferred"`
}

var handlers = map[string]handler{
	"hello": func(_ context.Context, s *server, _ json.RawMessage) (any, error) {
		return map[string]string{"version": s.version}, nil
	},
	"configure": func(_ context.Context, s *server, raw json.RawMessage) (any, error) {
		cfg, err := decode[engine.Config](raw)
		if err != nil {
			return nil, err
		}
		e, err := engine.New(cfg)
		if err != nil {
			return nil, fmt.Errorf("configure: %w", err)
		}
		s.mu.Lock()
		s.engine = e
		s.mu.Unlock()
		return true, nil
	},
	"revision": method(func(_ context.Context, e *engine.Engine, _ none) (string, error) {
		return e.Revision()
	}),
	"counts": method(func(_ context.Context, e *engine.Engine, p struct {
		Queries []string `json:"queries"`
	}) ([]int, error) {
		return e.Counts(p.Queries)
	}),
	"threads": method(func(_ context.Context, e *engine.Engine, p struct {
		Query  string `json:"query"`
		Offset int    `json:"offset"`
		Limit  int    `json:"limit"`
		Count  bool   `json:"count"`
	}) (engine.ThreadPage, error) {
		return e.Threads(p.Query, notmuch.NewestFirst, p.Offset, p.Limit, p.Count)
	}),
	"count_threads": method(func(_ context.Context, e *engine.Engine, p struct {
		Query string `json:"query"`
	}) (int, error) {
		return e.CountThreads(p.Query)
	}),
	"prefetch": method(func(_ context.Context, e *engine.Engine, p struct {
		Queries []string `json:"queries"`
		Limit   int      `json:"limit"`
	}) (bool, error) {
		e.Prefetch(p.Queries, p.Limit)
		return true, nil
	}),
	"newest_message": method(func(_ context.Context, e *engine.Engine, p struct {
		Thread string `json:"thread"`
		Query  string `json:"query"`
	}) (string, error) {
		return e.NewestMessage(p.Thread, p.Query)
	}),
	"message": method(func(_ context.Context, e *engine.Engine, p struct {
		ID           string         `json:"id"`
		Alternatives []string       `json:"alternatives"`
		Render       *engine.Render `json:"render"`
	}) (engine.MessageView, error) {
		return e.Message(p.ID, p.Alternatives, p.Render)
	}),
	"thread": method(func(_ context.Context, e *engine.Engine, p struct {
		ID     string         `json:"id"`
		Render *engine.Render `json:"render"`
	}) ([]engine.MessageView, error) {
		return e.Thread(p.ID, p.Render)
	}),
	"warm": method(func(_ context.Context, e *engine.Engine, p struct {
		IDs    []string       `json:"ids"`
		Render *engine.Render `json:"render"`
	}) (bool, error) {
		e.Warm(p.IDs, p.Render)
		return true, nil
	}),
	"render": method(func(_ context.Context, e *engine.Engine, p struct {
		Blocks []view.Block  `json:"blocks"`
		Render engine.Render `json:"render"`
	}) (doc.Doc, error) {
		return e.Layout(p.Blocks, p.Render)
	}),
	"tag": method(func(_ context.Context, e *engine.Engine, p struct {
		IDs     []string `json:"ids"`
		Changes []string `json:"changes"`
	}) (bool, error) {
		return true, e.Tag(p.IDs, p.Changes)
	}),
	"extract": method(func(_ context.Context, e *engine.Engine, p struct {
		ID   string `json:"id"`
		Part int    `json:"part"`
		Path string `json:"path"`
	}) (int, error) {
		return e.Extract(p.ID, p.Part, p.Path)
	}),
	"reply": method(func(_ context.Context, e *engine.Engine, p struct {
		ID        string `json:"id"`
		All       bool   `json:"all"`
		Preferred int    `json:"preferred"`
	}) (engine.ReplyHeaders, error) {
		return e.Reply(p.ID, p.All, p.Preferred)
	}),
	"addresses": method(func(_ context.Context, e *engine.Engine, _ none) ([]engine.RankedAddress, error) {
		return e.Addresses()
	}),
	"relocate": method(func(_ context.Context, e *engine.Engine, p struct {
		IDs       []string      `json:"ids"`
		Action    engine.Action `json:"action"`
		Folder    string        `json:"folder"`
		Stash     string        `json:"stash"`
		Preferred int           `json:"preferred"`
	}) (engine.Undo, error) {
		return e.Relocate(p.IDs, p.Action, p.Folder, p.Stash, p.Preferred)
	}),
	"undo": method(func(_ context.Context, e *engine.Engine, p engine.Undo) (bool, error) {
		return true, e.Undo(p)
	}),
	"permanent_delete": method(func(_ context.Context, e *engine.Engine, p idsParams) (bool, error) {
		return e.PermanentDelete(p.IDs, p.Preferred)
	}),
	"folders": method(func(_ context.Context, e *engine.Engine, p idsParams) ([]string, error) {
		return e.Folders(p.IDs, p.Preferred)
	}),
	"calendar_reply": method(func(_ context.Context, e *engine.Engine, p struct {
		ID        string            `json:"id"`
		Status    calendar.PartStat `json:"status"`
		Preferred int               `json:"preferred"`
	}) (engine.CalendarDraft, error) {
		return e.CalendarReply(p.ID, p.Status, p.Preferred)
	}),
	"check_draft": method(func(_ context.Context, e *engine.Engine, p engine.Draft) (bool, error) {
		return true, e.CheckDraft(p)
	}),
	"save_draft": method(func(_ context.Context, e *engine.Engine, p engine.Draft) (string, error) {
		return e.SaveDraft(p)
	}),
	"send": method(func(ctx context.Context, e *engine.Engine, p engine.Draft) (bool, error) {
		return true, e.Send(ctx, p)
	}),
}

func Serve(ctx context.Context, version string, in io.Reader, out io.Writer) error {
	s := &server{version: version}
	reader := bufio.NewReaderSize(in, 1<<16)
	encoder := json.NewEncoder(out)
	encoder.SetEscapeHTML(false)
	var writes sync.Mutex
	var inflight sync.WaitGroup
	reply := func(r response) error {
		writes.Lock()
		defer writes.Unlock()
		if err := encoder.Encode(r); err != nil {
			return fmt.Errorf("writing response %d: %w", r.ID, err)
		}
		return nil
	}
	defer inflight.Wait()
	for {
		line, err := reader.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			var req request
			if decodeErr := json.Unmarshal(line, &req); decodeErr != nil {
				return fmt.Errorf("reading request: %w", decodeErr)
			}
			answer := func() {
				result, callErr := dispatch(ctx, s, req)
				r := response{ID: req.ID, Result: result}
				if callErr != nil {
					r = response{ID: req.ID, Error: fmt.Sprintf("%s: %v", req.Method, callErr)}
				}
				_ = reply(r)
			}
			if req.Method == "configure" {
				inflight.Wait()
				answer()
			} else {
				inflight.Go(answer)
			}
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("reading requests: %w", err)
		}
	}
}

func dispatch(ctx context.Context, s *server, req request) (result any, err error) {
	h, ok := handlers[req.Method]
	if !ok {
		return nil, fmt.Errorf("unknown method")
	}
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("internal error: %v", r)
		}
	}()
	return h(ctx, s, req.Params)
}
