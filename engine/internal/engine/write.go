package engine

import (
	"errors"
	"fmt"
	"os"
	"slices"

	"github.com/stubbedev/email.nvim/engine/internal/maildir"
	"github.com/stubbedev/email.nvim/engine/internal/notmuch"
)

type Action string

const (
	Archive Action = "archive"
	Delete  Action = "delete"
	Move    Action = "move"
)

type Undo struct {
	Journal       maildir.Journal `json:"journal"`
	WasInInbox    []string        `json:"was_in_inbox"`
	WasNotInInbox []string        `json:"was_not_in_inbox"`
}

func (e *Engine) Tag(ids, changes []string) error {
	parsed, err := notmuch.ParseTagChanges(changes)
	if err != nil {
		return err
	}
	return e.write(func(db *notmuch.Database) error { return db.Tag(ids, parsed) })
}

func retagInbox(db *notmuch.Database, into, outOf []string) error {
	if len(into) > 0 {
		if err := db.Tag(into, []notmuch.TagChange{{Tag: "inbox", Add: true}}); err != nil {
			return err
		}
	}
	if len(outOf) > 0 {
		return db.Tag(outOf, []notmuch.TagChange{{Tag: "inbox", Add: false}})
	}
	return nil
}

func reindex(db *notmuch.Database, entries []maildir.Entry) error {
	for _, entry := range entries {
		if entry.Kind == maildir.Moved {
			if _, err := db.Index(entry.To); err != nil {
				return err
			}
		}
		if err := db.Remove(entry.From); err != nil {
			return err
		}
	}
	return nil
}

func reindexRestored(db *notmuch.Database, restored []maildir.Restored) error {
	for _, r := range restored {
		if _, err := db.Index(r.Path); err != nil {
			return err
		}
		if r.Replaced != "" {
			if err := db.Remove(r.Replaced); err != nil {
				return err
			}
		}
	}
	return nil
}

type target struct {
	folder string
	unlink bool
}

func (e *Engine) destination(account *Account, files []string, action Action, folder string) (target, error) {
	switch action {
	case Archive:
		if account.Archive == "" {
			return target{}, fmt.Errorf("account %s has no archive folder", account.Name)
		}
		return target{folder: account.Archive}, nil
	case Delete:
		if account.Trash == "" || maildir.InFolder(files, account.Root, account.Trash) {
			return target{unlink: true}, nil
		}
		return target{folder: account.Trash}, nil
	case Move:
		if folder == "" {
			return target{}, errors.New("move needs a folder")
		}
		return target{folder: folder}, nil
	default:
		return target{}, fmt.Errorf("unknown action %q", action)
	}
}

func (e *Engine) Relocate(ids []string, action Action, folder, stash string, preferred int) (Undo, error) {
	undo := Undo{Journal: maildir.Journal{Stash: stash}, WasInInbox: []string{}, WasNotInInbox: []string{}}
	if len(e.accounts) == 0 {
		return undo, errNoAccounts
	}
	if err := os.MkdirAll(stash, 0o700); err != nil {
		return undo, fmt.Errorf("creating undo stash %s: %w", stash, err)
	}
	err := e.write(func(db *notmuch.Database) error {
		var into, outOf []string
		err := func() error {
			for _, id := range ids {
				m, err := db.Message(id)
				if err != nil {
					return err
				}
				account, err := e.owner(id, m.Files, preferred)
				if err != nil {
					return err
				}
				dest, err := e.destination(account, m.Files, action, folder)
				if err != nil {
					return err
				}
				wasInInbox := slices.ContainsFunc(m.Files, func(file string) bool {
					at, _, ok := maildir.Split(file, account.Root)
					return ok && at == account.Inbox
				})
				before := len(undo.Journal.Entries)
				if dest.unlink {
					err = undo.Journal.Unlink(m.Files, account.Root)
				} else {
					err = undo.Journal.Move(m.Files, account.Root, dest.folder)
				}
				if err := errors.Join(err, reindex(db, undo.Journal.Entries[before:])); err != nil {
					return fmt.Errorf("message %s: %w", id, err)
				}
				switch {
				case dest.unlink:
				case dest.folder == account.Inbox:
					into = append(into, id)
				default:
					outOf = append(outOf, id)
				}
				if wasInInbox {
					undo.WasInInbox = append(undo.WasInInbox, id)
				} else {
					undo.WasNotInInbox = append(undo.WasNotInInbox, id)
				}
			}
			return retagInbox(db, into, outOf)
		}()
		if err == nil {
			return nil
		}
		restored, undoErr := undo.Journal.Undo()
		return errors.Join(err, undoErr, reindexRestored(db, restored))
	})
	return undo, err
}

func (e *Engine) Undo(undo Undo) error {
	return e.write(func(db *notmuch.Database) error {
		restored, err := undo.Journal.Undo()
		if err := errors.Join(err, reindexRestored(db, restored)); err != nil {
			return err
		}
		return retagInbox(db, undo.WasInInbox, undo.WasNotInInbox)
	})
}

func (e *Engine) PermanentDelete(ids []string, preferred int) (bool, error) {
	permanent := false
	err := e.read(func(db *notmuch.Database) error {
		for _, id := range ids {
			m, err := db.Message(id)
			if err != nil {
				return err
			}
			account, err := e.owner(id, m.Files, preferred)
			if err != nil {
				return err
			}
			dest, err := e.destination(account, m.Files, Delete, "")
			if err != nil {
				return err
			}
			permanent = permanent || dest.unlink
		}
		return nil
	})
	return permanent, err
}

func (e *Engine) Folders(ids []string, preferred int) ([]string, error) {
	var account *Account
	err := e.read(func(db *notmuch.Database) error {
		for _, id := range ids {
			m, err := db.Message(id)
			if err != nil {
				return err
			}
			owner, err := e.owner(id, m.Files, preferred)
			if err != nil {
				return err
			}
			if account != nil && owner != account {
				return errors.New("the selected messages belong to different accounts")
			}
			account = owner
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if account == nil {
		return nil, errors.New("no message selected")
	}
	return maildir.Folders(account.Root)
}
