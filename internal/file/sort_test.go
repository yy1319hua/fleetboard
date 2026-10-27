package file

import (
	"testing"
	"time"
)

func mkEntry(name string, dir bool, size int64, mod time.Time) Entry {
	return Entry{Name: name, Dir: dir, Size: size, ModTime: mod}
}

func TestSortDirsFirst(t *testing.T) {
	now := time.Now()
	entries := []Entry{
		mkEntry("b.txt", false, 10, now),
		mkEntry("adir", true, 0, now),
		mkEntry("a.txt", false, 5, now),
	}

	SortEntries(entries, "name", "asc")

	if !entries[0].Dir {
		t.Error("目录应排最前")
	}
	if entries[1].Name != "a.txt" || entries[2].Name != "b.txt" {
		t.Errorf("文件顺序错误: %v", names(entries))
	}
}

func TestSortByNameDesc(t *testing.T) {
	now := time.Now()
	entries := []Entry{
		mkEntry("a", false, 1, now),
		mkEntry("c", false, 3, now),
		mkEntry("b", false, 2, now),
	}

	SortEntries(entries, "name", "desc")

	if entries[0].Name != "c" || entries[2].Name != "a" {
		t.Errorf("降序错误: %v", names(entries))
	}
}

func TestSortBySize(t *testing.T) {
	now := time.Now()
	entries := []Entry{
		mkEntry("big", false, 100, now),
		mkEntry("small", false, 1, now),
	}

	SortEntries(entries, "size", "asc")

	if entries[0].Name != "small" {
		t.Errorf("按大小升序错误: %v", names(entries))
	}
}

func TestSortByModTime(t *testing.T) {
	old := time.Now().Add(-time.Hour)
	recent := time.Now()
	entries := []Entry{
		mkEntry("new", false, 0, recent),
		mkEntry("old", false, 0, old),
	}

	SortEntries(entries, "mod_time", "asc")

	if entries[0].Name != "old" {
		t.Errorf("按时间升序错误: %v", names(entries))
	}
}

func TestPaginate(t *testing.T) {
	entries := make([]Entry, 10)
	for i := range entries {
		entries[i].Name = string(rune('a' + i))
	}

	got := Paginate(entries, 2, 3)
	if len(got) != 3 || got[0].Name != "c" {
		t.Errorf("分页错误: %v", names(got))
	}

	if got := Paginate(entries, 100, 5); len(got) != 0 {
		t.Errorf("offset 越界应返回空，实际 %v", names(got))
	}

	if got := Paginate(entries, 0, 0); len(got) != 10 {
		t.Errorf("limit<=0 应默认 200，实际 len=%d", len(got))
	}

	if got := Paginate(entries, 8, 5); len(got) != 2 {
		t.Errorf("尾部截断错误，len=%d", len(got))
	}
}

func names(entries []Entry) []string {
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = e.Name
	}
	return out
}
