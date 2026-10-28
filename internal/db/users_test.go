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

// M8.1a 自举兜底：users 空 + BOOTSTRAP_* 缺 → 生成随机账密；齐全则用之；已有用户跳过。
func TestEnsureBootstrapAdmin(t *testing.T) {
	open := func(t *testing.T) *sql.DB {
		t.Helper()
		d, err := Open(filepath.Join(t.TempDir(), "t.db"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { d.Close() })
		return d
	}

	t.Run("随机生成", func(t *testing.T) {
		d := open(t)
		user, pass, generated, created, err := EnsureBootstrapAdmin(d, "", "")
		if err != nil || !created || !generated {
			t.Fatalf("err=%v created=%v generated=%v", err, created, generated)
		}
		if user != "admin" || len(pass) < 12 {
			t.Errorf("user=%q pass长度=%d", user, len(pass))
		}
		usr, err := GetUserByUsername(d, "admin")
		if err != nil || !auth.VerifyPassword(usr.PasswordHash, pass) {
			t.Errorf("生成的账密应可登录: %v", err)
		}
	})

	t.Run("BOOTSTRAP齐全用之", func(t *testing.T) {
		d := open(t)
		user, pass, generated, created, err := EnsureBootstrapAdmin(d, "ops", "secret99")
		if err != nil || !created || generated || user != "ops" || pass != "secret99" {
			t.Fatalf("err=%v created=%v generated=%v user=%q", err, created, generated, user)
		}
	})

	t.Run("已有用户跳过", func(t *testing.T) {
		d := open(t)
		if _, _, _, _, err := EnsureBootstrapAdmin(d, "a", "aaaa1111"); err != nil {
			t.Fatal(err)
		}
		_, _, _, created, err := EnsureBootstrapAdmin(d, "b", "bbbb2222")
		if err != nil || created {
			t.Errorf("已有用户应跳过: created=%v err=%v", created, err)
		}
	})
}
