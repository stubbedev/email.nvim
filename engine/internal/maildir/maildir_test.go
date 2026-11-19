package maildir

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func fixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, folder := range []string{"INBOX", "Archive", "[Gmail]/All Mail"} {
		for _, sub := range []string{"cur", "new", "tmp"} {
			if err := os.MkdirAll(filepath.Join(root, folder, sub), 0o700); err != nil {
				t.Fatal(err)
			}
		}
	}
	return root
}

func touch(t *testing.T, path string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func TestSplit(t *testing.T) {
	folder, name, ok := Split("/r/[Gmail]/All Mail/cur/1.2_3.host,U=9:2,S", "/r")
	if !ok || folder != "[Gmail]/All Mail" || name != "1.2_3.host,U=9:2,S" {
		t.Errorf("got %q %q %v", folder, name, ok)
	}
	for _, path := range []string{"/other/INBOX/cur/x", "/r/INBOX/tmp/x", "/r/cur/x"} {
		if _, _, ok := Split(path, "/r"); ok {
			t.Errorf("Split(%q) matched", path)
		}
	}
}

func TestTargetNameDropsTheUIDAndKeepsFlags(t *testing.T) {
	if got := TargetName("1.2_3.host,U=42:2,FS"); got != "1.2_3.host:2,FS" {
		t.Error(got)
	}
	if got := TargetName("1.2_3.host,U=42"); got != "1.2_3.host:2," {
		t.Error(got)
	}
}

func TestMoveAndUndo(t *testing.T) {
	root := fixture(t)
	inbox := touch(t, filepath.Join(root, "INBOX/cur/a,U=1:2,S"))
	all := touch(t, filepath.Join(root, "[Gmail]/All Mail/cur/b,U=2:2,S"))
	j := &Journal{Stash: t.TempDir()}
	if err := j.Move([]string{inbox, all}, root, "Archive"); err != nil {
		t.Fatal(err)
	}
	if exists(inbox) || exists(all) || !exists(filepath.Join(root, "Archive/cur/a:2,S")) {
		t.Fatal("move did not happen")
	}
	restored, err := j.Undo()
	if err != nil {
		t.Fatal(err)
	}
	if len(restored) != 2 || !exists(filepath.Join(root, "INBOX/cur/a:2,S")) || !exists(filepath.Join(root, "[Gmail]/All Mail/cur/b:2,S")) || exists(filepath.Join(root, "Archive/cur/a:2,S")) {
		t.Errorf("undo restored %+v", restored)
	}
}

func TestMoveOnlyUnlinksWhenTheTargetHasACopy(t *testing.T) {
	root := fixture(t)
	inbox := touch(t, filepath.Join(root, "INBOX/cur/a,U=1:2,S"))
	all := touch(t, filepath.Join(root, "[Gmail]/All Mail/cur/b,U=2:2,S"))
	j := &Journal{Stash: t.TempDir()}
	if err := j.Move([]string{inbox, all}, root, "[Gmail]/All Mail"); err != nil {
		t.Fatal(err)
	}
	if exists(inbox) || !exists(all) {
		t.Error("expected only the inbox copy removed")
	}
}

func TestMoveFailsWhenNoFileIsTheAccounts(t *testing.T) {
	root := fixture(t)
	other := touch(t, filepath.Join(t.TempDir(), "INBOX/cur/z:2,"))
	err := (&Journal{Stash: t.TempDir()}).Move([]string{other}, root, "Archive")
	if err == nil || !strings.Contains(err.Error(), "no file of the message") || !exists(other) {
		t.Errorf("err = %v", err)
	}
}

func TestUnlinkKeepsACopyForUndo(t *testing.T) {
	root := fixture(t)
	file := touch(t, filepath.Join(root, "INBOX/cur/gone,U=3:2,S"))
	j := &Journal{Stash: t.TempDir()}
	if err := j.Unlink([]string{file}, root); err != nil {
		t.Fatal(err)
	}
	if exists(file) {
		t.Fatal("not removed")
	}
	if _, err := j.Undo(); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(root, "INBOX/cur/gone:2,S")); err != nil || string(data) != "x" { //nolint:gosec
		t.Errorf("restored %q %v", data, err)
	}
}

func TestInFolder(t *testing.T) {
	cases := []struct {
		files []string
		want  bool
	}{
		{[]string{"/r/Trash/cur/a"}, true},
		{[]string{"/r/Trash/cur/a", "/r/INBOX/cur/b"}, false},
		{[]string{"/r/Trash/cur/a", "/other/INBOX/cur/b"}, true},
		{[]string{"/other/Trash/cur/a"}, false},
	}
	for _, c := range cases {
		if got := InFolder(c.files, "/r", "Trash"); got != c.want {
			t.Errorf("InFolder(%v) = %v", c.files, got)
		}
	}
}

func TestFoldersAndDeliver(t *testing.T) {
	root := fixture(t)
	got, err := Folders(root)
	if err != nil || !slices.Equal(got, []string{"Archive", "INBOX", "[Gmail]/All Mail"}) {
		t.Errorf("folders = %v %v", got, err)
	}
	path, err := Deliver(root, "Archive", []byte("mail"), "S")
	if err != nil {
		t.Fatal(err)
	}
	if folder, name, ok := Split(path, root); !ok || folder != "Archive" || !strings.HasSuffix(name, ":2,S") {
		t.Errorf("delivered to %s", path)
	}
	if entries, _ := os.ReadDir(filepath.Join(root, "Archive/tmp")); len(entries) != 0 {
		t.Errorf("tmp left behind: %v", entries)
	}
}
