package sshpool

import (
	"context"
	"errors"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestAuthMethodsPassword(t *testing.T) {
	cfg := Config{AuthMethod: "password", Password: "p"}
	methods, err := cfg.authMethods()
	if err != nil {
		t.Fatalf("authMethods: %v", err)
	}
	if len(methods) != 1 {
		t.Errorf("len=%d, want 1", len(methods))
	}
}

func TestAuthMethodsPasswordEmpty(t *testing.T) {
	cfg := Config{AuthMethod: "password"}
	if _, err := cfg.authMethods(); err == nil {
		t.Error("密码为空应报错")
	}
}

func TestAuthMethodsKeyEmpty(t *testing.T) {
	cfg := Config{AuthMethod: "key"}
	if _, err := cfg.authMethods(); err == nil {
		t.Error("私钥为空应报错")
	}
}

func TestAuthMethodsUnknown(t *testing.T) {
	cfg := Config{AuthMethod: "weird"}
	if _, err := cfg.authMethods(); err == nil {
		t.Error("未知认证方式应报错")
	}
}

func TestConfigDefaults(t *testing.T) {
	cfg := Config{Host: "1.2.3.4"}
	if cfg.port() != 22 {
		t.Errorf("port=%d, want 22", cfg.port())
	}
	if cfg.user() != "root" {
		t.Errorf("user=%q, want root", cfg.user())
	}
	if cfg.addr() != "1.2.3.4:22" {
		t.Errorf("addr=%q", cfg.addr())
	}
}

func TestPoolEmpty(t *testing.T) {
	p := NewPool(time.Minute)
	if p.Len() != 0 {
		t.Errorf("Len=%d, want 0", p.Len())
	}
	if n := p.Reap(); n != 0 {
		t.Errorf("Reap=%d, want 0", n)
	}
	p.Close(1)
	p.CloseAll()
	if p.Len() != 0 {
		t.Errorf("Len=%d, want 0", p.Len())
	}
}

func TestGetDialError(t *testing.T) {
	p := NewPool(time.Minute)
	p.SetDialer(func(ctx context.Context, cfg Config) (*ssh.Client, error) {
		return nil, errors.New("dial boom")
	})

	if _, err := p.Get(context.Background(), 1, Config{Host: "x"}); err == nil {
		t.Fatal("建连失败应返回错误")
	}
	if p.Len() != 0 {
		t.Errorf("建连失败不应缓存连接，Len=%d", p.Len())
	}
}
