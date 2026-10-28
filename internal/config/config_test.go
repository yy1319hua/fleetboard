package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadMissingKey(t *testing.T) {
	t.Setenv("KEY", "")
	t.Setenv("JWT_SECRET", "s")
	if _, err := Load(); err == nil {
		t.Fatal("缺 KEY 应报错")
	}
}

// JWT_SECRET 已入库 settings（M8.1b）：缺失不再报错，启动时自动生成并入库。
func TestLoadMissingJWTOk(t *testing.T) {
	t.Setenv("KEY", "k")
	t.Setenv("JWT_SECRET", "")
	if _, err := Load(); err != nil {
		t.Fatalf("缺 JWT_SECRET 不应报错: %v", err)
	}
}

func TestLoadDefaultsAndEnv(t *testing.T) {
	t.Setenv("KEY", "k")
	t.Setenv("JWT_SECRET", "s")
	t.Setenv("PORT", "9090")
	t.Setenv("DATA_DIR", "/tmp/fb")
	t.Setenv("MONITOR_INTERVAL", "15")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Port != 9090 {
		t.Errorf("Port=%d, want 9090", cfg.Port)
	}
	if cfg.DataDir != "/tmp/fb" {
		t.Errorf("DataDir=%q, want /tmp/fb", cfg.DataDir)
	}
	if cfg.MonitorIntervalSec != 15 {
		t.Errorf("MonitorIntervalSec=%d, want 15", cfg.MonitorIntervalSec)
	}
	if cfg.DBPath != "/tmp/fb/fleetboard.db" {
		t.Errorf("DBPath=%q", cfg.DBPath)
	}
}

func TestLoadInvalidPort(t *testing.T) {
	t.Setenv("KEY", "k")
	t.Setenv("JWT_SECRET", "s")
	t.Setenv("PORT", "notnum")
	if _, err := Load(); err == nil {
		t.Fatal("非法 PORT 应报错")
	}
}

func TestLoadInvalidPortRange(t *testing.T) {
	t.Setenv("KEY", "k")
	t.Setenv("JWT_SECRET", "s")
	t.Setenv("PORT", "70000")
	if _, err := Load(); err == nil {
		t.Fatal("PORT 超出范围应报错")
	}
}

func TestLoadDotEnv(t *testing.T) {
	dir := t.TempDir()
	envPath := filepath.Join(dir, ".env")
	if err := os.WriteFile(envPath, []byte("KEY=envkey\nJWT_SECRET=envsecret\nPORT=7070\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	keys := []string{"KEY", "JWT_SECRET", "PORT"}
	type saved struct {
		v   string
		had bool
	}
	old := make(map[string]saved, len(keys))
	for _, k := range keys {
		v, had := os.LookupEnv(k)
		old[k] = saved{v, had}
		_ = os.Unsetenv(k)
	}
	t.Cleanup(func() {
		for _, k := range keys {
			if old[k].had {
				_ = os.Setenv(k, old[k].v)
			} else {
				_ = os.Unsetenv(k)
			}
		}
	})

	if err := loadDotEnv(envPath); err != nil {
		t.Fatalf("loadDotEnv: %v", err)
	}
	if got := os.Getenv("KEY"); got != "envkey" {
		t.Errorf("KEY=%q, want envkey", got)
	}
	if got := os.Getenv("JWT_SECRET"); got != "envsecret" {
		t.Errorf("JWT_SECRET=%q, want envsecret", got)
	}
	if got := os.Getenv("PORT"); got != "7070" {
		t.Errorf("PORT=%q, want 7070", got)
	}
}

func TestLoadDotEnvDoesNotOverride(t *testing.T) {
	dir := t.TempDir()
	envPath := filepath.Join(dir, ".env")
	if err := os.WriteFile(envPath, []byte("KEY=fromfile\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KEY", "fromenv")

	if err := loadDotEnv(envPath); err != nil {
		t.Fatalf("loadDotEnv: %v", err)
	}
	if got := os.Getenv("KEY"); got != "fromenv" {
		t.Errorf("KEY=%q, 应保留环境变量值而非被 .env 覆盖", got)
	}
}
