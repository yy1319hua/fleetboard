package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"testing"

	"github.com/yy1319hua/fleetboard/internal/auth"
)

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	d, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return d
}

func TestEnsureAdminCreates(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	created, err := EnsureAdmin(d, "admin", "pass123")
	if err != nil {
		t.Fatalf("EnsureAdmin: %v", err)
	}
	if !created {
		t.Fatal("首次应创建管理员")
	}

	if n, err := CountUsers(d); err != nil || n != 1 {
		t.Fatalf("users=%d err=%v", n, err)
	}

	u, err := GetUserByUsername(d, "admin")
	if err != nil {
		t.Fatalf("GetUserByUsername: %v", err)
	}
	if u.PasswordHash == "pass123" {
		t.Error("密码不应以明文存储")
	}
	if !auth.VerifyPassword(u.PasswordHash, "pass123") {
		t.Error("密码哈希校验失败")
	}

	// 二次调用：已有用户，跳过
	created2, err := EnsureAdmin(d, "admin", "pass123")
	if err != nil {
		t.Fatalf("二次 EnsureAdmin: %v", err)
	}
	if created2 {
		t.Error("已有用户时不应重复创建")
	}
	if n, _ := CountUsers(d); n != 1 {
		t.Errorf("users=%d, want 1", n)
	}
}

func TestEnsureAdminSkipsEmpty(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	created, err := EnsureAdmin(d, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if created {
		t.Error("空账号不应创建")
	}
	if n, _ := CountUsers(d); n != 0 {
		t.Errorf("users=%d, want 0", n)
	}
}

func TestGetUserNotFound(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	_, err := GetUserByUsername(d, "nobody")
	if !errors.Is(err, ErrUserNotFound) {
		t.Errorf("err=%v, want ErrUserNotFound", err)
	}
}
