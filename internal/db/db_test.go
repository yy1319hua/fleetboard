package db

import (
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// migrationFiles 返回 embed 里按文件名排序的迁移清单。
//
// 这里原先写死 "0005_system_upgrades.sql" 与 want 5：每加一个迁移都要改测试，
// 漏改就红在与本次改动无关的地方，改错还会掩盖真实问题。改成动态取。
func migrationFiles(t *testing.T) []string {
	t.Helper()
	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		t.Fatalf("读取 migrations: %v", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		t.Fatal("没有任何迁移文件")
	}
	sort.Strings(names)
	return names
}

func TestOpenAndMigrate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()

	for _, table := range []string{
		"users", "servers", "ssh_credentials", "operation_log", "settings", "file_cache",
		"server_metrics", "alert_rules", "alert_events", "system_upgrades", "server_facts",
	} {
		var n int
		if err := d.QueryRow(
			`SELECT COUNT(1) FROM sqlite_master WHERE type='table' AND name=?`, table,
		).Scan(&n); err != nil {
			t.Fatalf("查询表 %s: %v", table, err)
		}
		if n != 1 {
			t.Errorf("表 %s 不存在", table)
		}
	}

	v, err := Version(d)
	if err != nil {
		t.Fatalf("Version: %v", err)
	}
	files := migrationFiles(t)
	if want := files[len(files)-1]; v != want {
		t.Errorf("Version=%q, want %q", v, want)
	}
}

func TestOpenIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	d1, err := Open(path)
	if err != nil {
		t.Fatalf("第一次 Open: %v", err)
	}
	_ = d1.Close()

	d2, err := Open(path)
	if err != nil {
		t.Fatalf("第二次 Open: %v", err)
	}
	defer d2.Close()

	var n int
	if err := d2.QueryRow(`SELECT COUNT(1) FROM schema_migrations`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if want := len(migrationFiles(t)); n != want {
		t.Errorf("迁移记录数=%d, want %d（重复打开不应重复应用）", n, want)
	}
}

func TestOpenCreatesParentDir(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "dir", "test.db")

	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open 应自动创建父目录: %v", err)
	}
	defer d.Close()

	files := migrationFiles(t)
	if v, err := Version(d); err != nil || v != files[len(files)-1] {
		t.Errorf("Version=%q err=%v", v, err)
	}
}
