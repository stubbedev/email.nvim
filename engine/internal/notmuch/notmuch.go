package notmuch

/*
#cgo LDFLAGS: -lnotmuch
#include <stdlib.h>
#include <notmuch.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"strings"
	"time"
	"unsafe"
)

type Mode int

const (
	ReadOnly Mode = iota
	ReadWrite
)

type Sort int

const (
	NewestFirst Sort = iota
	OldestFirst
)

const (
	lockWait  = 5 * time.Second
	lockRetry = 50 * time.Millisecond
)

type Database struct {
	db   *C.notmuch_database_t
	mode Mode
}

type Thread struct {
	ID         string
	Total      int
	Matched    int
	Authors    string
	Subject    string
	Newest     int64
	Tags       []string
	MatchedIDs []string
}

type Message struct {
	ID       string
	ThreadID string
	Files    []string
	Tags     []string
	Date     int64
	Match    bool
	From     string
}

type StatusError struct {
	Op     string
	Status string
	Detail string
}

func (e *StatusError) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("notmuch: %s: %s: %s", e.Op, e.Status, strings.TrimSpace(e.Detail))
	}
	return fmt.Sprintf("notmuch: %s: %s", e.Op, e.Status)
}

func statusError(op string, status C.notmuch_status_t) error {
	if status == C.NOTMUCH_STATUS_SUCCESS {
		return nil
	}
	return &StatusError{Op: op, Status: C.GoString(C.notmuch_status_to_string(status))}
}

func Open(mode Mode) (*Database, error) {
	cmode := C.notmuch_database_mode_t(C.NOTMUCH_DATABASE_MODE_READ_ONLY)
	if mode == ReadWrite {
		cmode = C.NOTMUCH_DATABASE_MODE_READ_WRITE
	}
	deadline := time.Now().Add(lockWait)
	for {
		var db *C.notmuch_database_t
		var detail *C.char
		status := C.notmuch_database_open_with_config(nil, cmode, nil, nil, &db, &detail)
		if status == C.NOTMUCH_STATUS_SUCCESS {
			return &Database{db: db, mode: mode}, nil
		}
		message := C.GoString(detail)
		C.free(unsafe.Pointer(detail))
		locked := mode == ReadWrite && status == C.NOTMUCH_STATUS_XAPIAN_EXCEPTION && strings.Contains(message, "lock")
		if !locked || time.Now().After(deadline) {
			return nil, &StatusError{Op: "open database", Status: C.GoString(C.notmuch_status_to_string(status)), Detail: message}
		}
		time.Sleep(lockRetry)
	}
}

func (d *Database) Close() error {
	if d.db == nil {
		return nil
	}
	err := statusError("close database", C.notmuch_database_destroy(d.db))
	d.db = nil
	return err
}

func (d *Database) Revision() (uint64, string) {
	var uuid *C.char
	revision := C.notmuch_database_get_revision(d.db, &uuid)
	return uint64(revision), C.GoString(uuid)
}

func (d *Database) configValues(key C.notmuch_config_key_t) []string {
	var out []string
	values := C.notmuch_config_get_values(d.db, key)
	if values == nil {
		return nil
	}
	defer C.notmuch_config_values_destroy(values)
	for ; C.notmuch_config_values_valid(values) != 0; C.notmuch_config_values_move_to_next(values) {
		if value := C.GoString(C.notmuch_config_values_get(values)); value != "" {
			out = append(out, value)
		}
	}
	return out
}

func (d *Database) ExcludeTags() []string { return d.configValues(C.NOTMUCH_CONFIG_EXCLUDE_TAGS) }

func (d *Database) NewTags() []string { return d.configValues(C.NOTMUCH_CONFIG_NEW_TAGS) }

func (d *Database) MailRoot() string {
	roots := d.configValues(C.NOTMUCH_CONFIG_MAIL_ROOT)
	if len(roots) == 0 {
		return ""
	}
	return roots[0]
}

func (d *Database) SyncMaildirFlags() bool {
	var value C.notmuch_bool_t
	if C.notmuch_config_get_bool(d.db, C.NOTMUCH_CONFIG_SYNC_MAILDIR_FLAGS, &value) != C.NOTMUCH_STATUS_SUCCESS {
		return false
	}
	return value != 0
}

type query struct {
	q *C.notmuch_query_t
}

func (d *Database) query(text string, sort Sort, exclude C.notmuch_exclude_t) (*query, error) {
	ctext := C.CString(text)
	defer C.free(unsafe.Pointer(ctext))
	q := C.notmuch_query_create(d.db, ctext)
	if q == nil {
		return nil, fmt.Errorf("notmuch: create query %q: out of memory", text)
	}
	csort := C.notmuch_sort_t(C.NOTMUCH_SORT_NEWEST_FIRST)
	if sort == OldestFirst {
		csort = C.NOTMUCH_SORT_OLDEST_FIRST
	}
	C.notmuch_query_set_sort(q, csort)
	for _, tag := range d.ExcludeTags() {
		ctag := C.CString(tag)
		status := C.notmuch_query_add_tag_exclude(q, ctag)
		C.free(unsafe.Pointer(ctag))
		if status != C.NOTMUCH_STATUS_SUCCESS && status != C.NOTMUCH_STATUS_IGNORED {
			C.notmuch_query_destroy(q)
			return nil, statusError(fmt.Sprintf("exclude tag %q", tag), status)
		}
	}
	C.notmuch_query_set_omit_excluded(q, exclude)
	return &query{q: q}, nil
}

func (q *query) close() { C.notmuch_query_destroy(q.q) }

func tagList(tags *C.notmuch_tags_t) []string {
	out := []string{}
	if tags == nil {
		return out
	}
	for ; C.notmuch_tags_valid(tags) != 0; C.notmuch_tags_move_to_next(tags) {
		out = append(out, C.GoString(C.notmuch_tags_get(tags)))
	}
	C.notmuch_tags_destroy(tags)
	return out
}

func fileList(files *C.notmuch_filenames_t) []string {
	out := []string{}
	if files == nil {
		return out
	}
	for ; C.notmuch_filenames_valid(files) != 0; C.notmuch_filenames_move_to_next(files) {
		out = append(out, C.GoString(C.notmuch_filenames_get(files)))
	}
	C.notmuch_filenames_destroy(files)
	return out
}

func header(message *C.notmuch_message_t, name string) string {
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	return C.GoString(C.notmuch_message_get_header(message, cname))
}

func flag(m *C.notmuch_message_t, which C.notmuch_message_flag_t) (bool, error) {
	var set C.notmuch_bool_t
	if err := statusError("read message flag", C.notmuch_message_get_flag_st(m, which, &set)); err != nil {
		return false, err
	}
	return set != 0, nil
}

func messageOf(m *C.notmuch_message_t) (Message, error) {
	match, err := flag(m, C.NOTMUCH_MESSAGE_FLAG_MATCH)
	if err != nil {
		return Message{}, err
	}
	return Message{
		ID:       C.GoString(C.notmuch_message_get_message_id(m)),
		ThreadID: C.GoString(C.notmuch_message_get_thread_id(m)),
		Files:    fileList(C.notmuch_message_get_filenames(m)),
		Tags:     tagList(C.notmuch_message_get_tags(m)),
		Date:     int64(C.notmuch_message_get_date(m)),
		Match:    match,
		From:     header(m, "from"),
	}, nil
}

func (d *Database) Threads(text string, sort Sort, offset, limit int) ([]Thread, error) {
	q, err := d.query(text, sort, C.NOTMUCH_EXCLUDE_TRUE)
	if err != nil {
		return nil, err
	}
	defer q.close()
	var threads *C.notmuch_threads_t
	if err := statusError(fmt.Sprintf("search threads %q", text), C.notmuch_query_search_threads(q.q, &threads)); err != nil {
		return nil, err
	}
	defer C.notmuch_threads_destroy(threads)
	out := make([]Thread, 0, limit)
	for index := 0; C.notmuch_threads_valid(threads) != 0 && len(out) < limit; index++ {
		thread := C.notmuch_threads_get(threads)
		if index >= offset {
			t, err := threadOf(thread)
			if err != nil {
				C.notmuch_thread_destroy(thread)
				return nil, err
			}
			out = append(out, t)
		}
		C.notmuch_thread_destroy(thread)
		C.notmuch_threads_move_to_next(threads)
	}
	return out, nil
}

func joinAuthors(raw string) string {
	matched, others, found := strings.Cut(raw, "|")
	if !found {
		return strings.TrimSpace(raw)
	}
	parts := make([]string, 0, 2)
	for _, part := range []string{matched, others} {
		if part = strings.TrimSpace(part); part != "" {
			parts = append(parts, part)
		}
	}
	return strings.Join(parts, ", ")
}

func threadOf(t *C.notmuch_thread_t) (Thread, error) {
	thread := Thread{
		ID:      C.GoString(C.notmuch_thread_get_thread_id(t)),
		Total:   int(C.notmuch_thread_get_total_messages(t)),
		Matched: int(C.notmuch_thread_get_matched_messages(t)),
		Authors: joinAuthors(C.GoString(C.notmuch_thread_get_authors(t))),
		Subject: C.GoString(C.notmuch_thread_get_subject(t)),
		Newest:  int64(C.notmuch_thread_get_newest_date(t)),
		Tags:    tagList(C.notmuch_thread_get_tags(t)),
	}
	messages := C.notmuch_thread_get_messages(t)
	for ; C.notmuch_messages_valid(messages) != 0; C.notmuch_messages_move_to_next(messages) {
		m := C.notmuch_messages_get(messages)
		match, err := flag(m, C.NOTMUCH_MESSAGE_FLAG_MATCH)
		if err != nil {
			C.notmuch_message_destroy(m)
			C.notmuch_messages_destroy(messages)
			return Thread{}, err
		}
		if match {
			thread.MatchedIDs = append(thread.MatchedIDs, C.GoString(C.notmuch_message_get_message_id(m)))
		}
		C.notmuch_message_destroy(m)
	}
	C.notmuch_messages_destroy(messages)
	return thread, nil
}

func (d *Database) Messages(text string, sort Sort, limit int) ([]Message, error) {
	q, err := d.query(text, sort, C.NOTMUCH_EXCLUDE_TRUE)
	if err != nil {
		return nil, err
	}
	defer q.close()
	var messages *C.notmuch_messages_t
	if err := statusError(fmt.Sprintf("search messages %q", text), C.notmuch_query_search_messages(q.q, &messages)); err != nil {
		return nil, err
	}
	defer C.notmuch_messages_destroy(messages)
	out := []Message{}
	for ; C.notmuch_messages_valid(messages) != 0 && (limit <= 0 || len(out) < limit); C.notmuch_messages_move_to_next(messages) {
		m := C.notmuch_messages_get(messages)
		message, err := messageOf(m)
		C.notmuch_message_destroy(m)
		if err != nil {
			return nil, err
		}
		out = append(out, message)
	}
	return out, nil
}

func (d *Database) Headers(text, name string) ([]string, error) {
	q, err := d.query(text, NewestFirst, C.NOTMUCH_EXCLUDE_TRUE)
	if err != nil {
		return nil, err
	}
	defer q.close()
	var messages *C.notmuch_messages_t
	if err := statusError(fmt.Sprintf("search messages %q", text), C.notmuch_query_search_messages(q.q, &messages)); err != nil {
		return nil, err
	}
	defer C.notmuch_messages_destroy(messages)
	cname := C.CString(name)
	defer C.free(unsafe.Pointer(cname))
	var out []string
	for ; C.notmuch_messages_valid(messages) != 0; C.notmuch_messages_move_to_next(messages) {
		m := C.notmuch_messages_get(messages)
		if value := C.GoString(C.notmuch_message_get_header(m, cname)); value != "" {
			out = append(out, value)
		}
		C.notmuch_message_destroy(m)
	}
	return out, nil
}

func (d *Database) Tags(text string) ([]string, error) {
	q, err := d.query(text, NewestFirst, C.NOTMUCH_EXCLUDE_TRUE)
	if err != nil {
		return nil, err
	}
	defer q.close()
	var messages *C.notmuch_messages_t
	if err := statusError(fmt.Sprintf("search messages %q", text), C.notmuch_query_search_messages(q.q, &messages)); err != nil {
		return nil, err
	}
	defer C.notmuch_messages_destroy(messages)
	return tagList(C.notmuch_messages_collect_tags(messages)), nil
}

func (d *Database) AllTags() []string { return tagList(C.notmuch_database_get_all_tags(d.db)) }

func (d *Database) Header(id, name string) (string, error) {
	m, err := d.find(id)
	if err != nil {
		return "", err
	}
	defer C.notmuch_message_destroy(m)
	return header(m, name), nil
}

func (d *Database) count(text string, threads bool) (int, error) {
	q, err := d.query(text, NewestFirst, C.NOTMUCH_EXCLUDE_TRUE)
	if err != nil {
		return 0, err
	}
	defer q.close()
	var count C.uint
	var status C.notmuch_status_t
	if threads {
		status = C.notmuch_query_count_threads(q.q, &count)
	} else {
		status = C.notmuch_query_count_messages(q.q, &count)
	}
	if err := statusError(fmt.Sprintf("count %q", text), status); err != nil {
		return 0, err
	}
	return int(count), nil
}

func (d *Database) CountThreads(text string) (int, error) { return d.count(text, true) }

func (d *Database) CountMessages(text string) (int, error) { return d.count(text, false) }

var ErrNotFound = errors.New("notmuch: message not found")

func (d *Database) find(id string) (*C.notmuch_message_t, error) {
	cid := C.CString(id)
	defer C.free(unsafe.Pointer(cid))
	var m *C.notmuch_message_t
	if err := statusError(fmt.Sprintf("find message %s", id), C.notmuch_database_find_message(d.db, cid, &m)); err != nil {
		return nil, err
	}
	if m == nil {
		return nil, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	return m, nil
}

func (d *Database) Message(id string) (Message, error) {
	m, err := d.find(id)
	if err != nil {
		return Message{}, err
	}
	defer C.notmuch_message_destroy(m)
	return messageOf(m)
}

type TagChange struct {
	Tag string
	Add bool
}

func ParseTagChanges(changes []string) ([]TagChange, error) {
	out := make([]TagChange, 0, len(changes))
	for _, change := range changes {
		if len(change) < 2 || (change[0] != '+' && change[0] != '-') {
			return nil, fmt.Errorf("tag change %q must be +tag or -tag", change)
		}
		out = append(out, TagChange{Tag: change[1:], Add: change[0] == '+'})
	}
	return out, nil
}

func (d *Database) atomic(op string, fn func() error) error {
	if err := statusError(op+": begin", C.notmuch_database_begin_atomic(d.db)); err != nil {
		return err
	}
	runErr := fn()
	endErr := statusError(op+": end", C.notmuch_database_end_atomic(d.db))
	return errors.Join(runErr, endErr)
}

func (d *Database) Tag(ids []string, changes []TagChange) error {
	sync := d.SyncMaildirFlags()
	return d.atomic("tag", func() error {
		for _, id := range ids {
			m, err := d.find(id)
			if err != nil {
				return err
			}
			err = applyTags(m, changes, sync)
			C.notmuch_message_destroy(m)
			if err != nil {
				return fmt.Errorf("tag %s: %w", id, err)
			}
		}
		return nil
	})
}

func applyTags(m *C.notmuch_message_t, changes []TagChange, sync bool) error {
	if err := statusError("freeze", C.notmuch_message_freeze(m)); err != nil {
		return err
	}
	for _, change := range changes {
		ctag := C.CString(change.Tag)
		var status C.notmuch_status_t
		if change.Add {
			status = C.notmuch_message_add_tag(m, ctag)
		} else {
			status = C.notmuch_message_remove_tag(m, ctag)
		}
		C.free(unsafe.Pointer(ctag))
		if err := statusError(fmt.Sprintf("change tag %q", change.Tag), status); err != nil {
			C.notmuch_message_thaw(m)
			return err
		}
	}
	if err := statusError("thaw", C.notmuch_message_thaw(m)); err != nil {
		return err
	}
	if sync {
		return statusError("sync maildir flags", C.notmuch_message_tags_to_maildir_flags(m))
	}
	return nil
}

func (d *Database) Index(path string) (string, error) {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	opts := C.notmuch_database_get_default_indexopts(d.db)
	defer C.notmuch_indexopts_destroy(opts)
	var m *C.notmuch_message_t
	status := C.notmuch_database_index_file(d.db, cpath, opts, &m)
	if status != C.NOTMUCH_STATUS_SUCCESS && status != C.NOTMUCH_STATUS_DUPLICATE_MESSAGE_ID {
		return "", statusError("index "+path, status)
	}
	defer C.notmuch_message_destroy(m)
	if status == C.NOTMUCH_STATUS_SUCCESS {
		changes := make([]TagChange, 0)
		for _, tag := range d.NewTags() {
			changes = append(changes, TagChange{Tag: tag, Add: true})
		}
		if err := applyTags(m, changes, false); err != nil {
			return "", fmt.Errorf("tag new message %s: %w", path, err)
		}
	}
	if d.SyncMaildirFlags() {
		if err := statusError("read maildir flags of "+path, C.notmuch_message_maildir_flags_to_tags(m)); err != nil {
			return "", err
		}
	}
	return C.GoString(C.notmuch_message_get_message_id(m)), nil
}

func (d *Database) Remove(path string) error {
	cpath := C.CString(path)
	defer C.free(unsafe.Pointer(cpath))
	status := C.notmuch_database_remove_message(d.db, cpath)
	if status == C.NOTMUCH_STATUS_DUPLICATE_MESSAGE_ID {
		return nil
	}
	return statusError("remove "+path, status)
}
