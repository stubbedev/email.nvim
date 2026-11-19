package maildir

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

type EntryKind string

const (
	Moved   EntryKind = "moved"
	Removed EntryKind = "removed"
)

type Entry struct {
	Kind EntryKind `json:"kind"`
	From string    `json:"from"`
	To   string    `json:"to,omitempty"`
	Kept string    `json:"kept,omitempty"`
}

type Journal struct {
	Stash   string  `json:"stash"`
	Entries []Entry `json:"entries"`
}

var uidField = regexp.MustCompile(`,U=\d+`)

func Split(path, root string) (folder, name string, ok bool) {
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return "", "", false
	}
	dir, name := filepath.Split(rel)
	dir = strings.TrimSuffix(dir, string(filepath.Separator))
	sub := filepath.Base(dir)
	folder = filepath.Dir(dir)
	if (sub != "cur" && sub != "new") || folder == "." || folder == "" {
		return "", "", false
	}
	return filepath.ToSlash(folder), name, true
}

func TargetName(name string) string {
	base, info, found := strings.Cut(name, ":2,")
	if found {
		info = ":2," + info
	} else {
		info = ":2,"
	}
	return uidField.ReplaceAllString(base, "") + info
}

func InFolder(files []string, root, folder string) bool {
	found := false
	for _, file := range files {
		at, _, ok := Split(file, root)
		if ok && at != folder {
			return false
		}
		found = found || (ok && at == folder)
	}
	return found
}

func (j *Journal) remove(file string) error {
	kept := filepath.Join(j.Stash, strconv.Itoa(len(j.Entries)+1))
	if err := copyFile(file, kept); err != nil {
		return fmt.Errorf("keeping %s for undo: %w", file, err)
	}
	if err := os.Remove(file); err != nil {
		return fmt.Errorf("removing %s: %w", file, err)
	}
	j.Entries = append(j.Entries, Entry{Kind: Removed, From: file, Kept: kept})
	return nil
}

func (j *Journal) Move(files []string, root, target string) error {
	var sources []string
	inTarget := false
	for _, file := range files {
		folder, _, ok := Split(file, root)
		switch {
		case ok && folder == target:
			inTarget = true
		case ok:
			sources = append(sources, file)
		}
	}
	if len(sources) == 0 {
		if inTarget {
			return nil
		}
		return fmt.Errorf("no file of the message lives under %s", root)
	}
	if !inTarget {
		first := sources[0]
		sources = sources[1:]
		_, name, _ := Split(first, root)
		dest := filepath.Join(root, filepath.FromSlash(target), "cur", TargetName(name))
		if err := os.Rename(first, dest); err != nil {
			return fmt.Errorf("moving %s to %s: %w", first, dest, err)
		}
		j.Entries = append(j.Entries, Entry{Kind: Moved, From: first, To: dest})
	}
	for _, file := range sources {
		if err := j.remove(file); err != nil {
			return err
		}
	}
	return nil
}

func (j *Journal) Unlink(files []string, root string) error {
	removed := 0
	for _, file := range files {
		if _, _, ok := Split(file, root); ok {
			if err := j.remove(file); err != nil {
				return err
			}
			removed++
		}
	}
	if removed == 0 {
		return fmt.Errorf("no file of the message lives under %s", root)
	}
	return nil
}

func Home(path string) string {
	return filepath.Join(filepath.Dir(filepath.Dir(path)), "cur", TargetName(filepath.Base(path)))
}

type Restored struct {
	Path     string
	Replaced string
}

func (j *Journal) Undo() ([]Restored, error) {
	restored := make([]Restored, 0, len(j.Entries))
	for i, entry := range slices.Backward(j.Entries) {
		home := Home(entry.From)
		switch entry.Kind {
		case Moved:
			if err := os.Rename(entry.To, home); err != nil {
				return restored, fmt.Errorf("moving %s back to %s: %w", entry.To, home, err)
			}
			restored = append(restored, Restored{Path: home, Replaced: entry.To})
		case Removed:
			if err := copyFile(entry.Kept, home); err != nil {
				return restored, fmt.Errorf("restoring %s: %w", home, err)
			}
			restored = append(restored, Restored{Path: home})
		default:
			return restored, fmt.Errorf("undo journal entry %d has unknown kind %q", i, entry.Kind)
		}
	}
	return restored, nil
}

func Folders(root string) ([]string, error) {
	var out []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() || d.Name() != "cur" || path == filepath.Join(root, "cur") {
			return nil
		}
		rel, err := filepath.Rel(root, filepath.Dir(path))
		if err != nil {
			return err
		}
		out = append(out, filepath.ToSlash(rel))
		return filepath.SkipDir
	})
	if err != nil {
		return nil, fmt.Errorf("listing folders under %s: %w", root, err)
	}
	slices.Sort(out)
	return out, nil
}

func Deliver(root, folder string, data []byte, flags string) (string, error) {
	dir := filepath.Join(root, filepath.FromSlash(folder))
	unique, err := uniqueName()
	if err != nil {
		return "", err
	}
	tmp := filepath.Join(dir, "tmp", unique)
	dest := filepath.Join(dir, "cur", unique+":2,"+flags)
	if err := writeSynced(tmp, data); err != nil {
		return "", fmt.Errorf("delivering into %s: %w", folder, err)
	}
	if err := os.Rename(tmp, dest); err != nil {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("delivering into %s: %w", folder, err)
	}
	return dest, nil
}

func uniqueName() (string, error) {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("reading random bytes: %w", err)
	}
	host, err := os.Hostname()
	if err != nil {
		return "", fmt.Errorf("reading the hostname: %w", err)
	}
	host = strings.NewReplacer("/", `\057`, ":", `\072`).Replace(host)
	now := time.Now()
	return fmt.Sprintf("%d.M%dP%d_%s.%s", now.Unix(), now.Nanosecond()/1000, os.Getpid(), hex.EncodeToString(buf), host), nil
}

func writeSynced(path string, data []byte) (err error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600) //nolint:gosec
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := f.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	if _, err = f.Write(data); err != nil {
		return err
	}
	return f.Sync()
}

func copyFile(from, to string) (err error) {
	src, err := os.Open(from) //nolint:gosec
	if err != nil {
		return err
	}
	defer func() { _ = src.Close() }()
	dst, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600) //nolint:gosec
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := dst.Close(); err == nil {
			err = closeErr
		}
	}()
	if _, err = io.Copy(dst, src); err != nil {
		return err
	}
	return dst.Sync()
}
