package db

import (
	"path/filepath"
	"testing"
)

func TestOpenAndMigrate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.db")

	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer d.Close()

	for _, table := range []string{
		"users", "servers", "ssh_credentials", "operation_log", "settings", "file_cache",
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
	if v != "0001_init.sql" {
		t.Errorf("Version=%q, want 0001_init.sql", v)
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
	if n != 1 {
		t.Errorf("迁移记录数=%d, want 1（重复打开不应重复应用）", n)
	}
}

func TestOpenCreatesParentDir(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "dir", "test.db")

	d, err := Open(path)
	if err != nil {
		t.Fatalf("Open 应自动创建父目录: %v", err)
	}
	defer d.Close()

	if v, err := Version(d); err != nil || v != "0001_init.sql" {
		t.Errorf("Version=%q err=%v", v, err)
	}
}
