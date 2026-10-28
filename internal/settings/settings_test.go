package settings

import (
	"path/filepath"
	"testing"

	"github.com/yy1319hua/fleetboard/internal/crypto"
	"github.com/yy1319hua/fleetboard/internal/db"
)

func newStore(t *testing.T) *Store {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	s, err := Load(d, "test-master-key")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return s
}

// 无 env 无 DB：非敏感项回落内置默认；敏感项未设置。
func TestLoadDefaults(t *testing.T) {
	s := newStore(t)
	if v, ok, _ := s.Get("monitor.interval"); !ok || v != "30" {
		t.Errorf("monitor.interval = %q ok=%v, want 30", v, ok)
	}
	view, err := s.MaskedView()
	if err != nil {
		t.Fatalf("MaskedView: %v", err)
	}
	secretView := view["pushplus.token"].(map[string]any)
	if secretView["set"] != false {
		t.Errorf("未设置的敏感项 set 应为 false: %v", secretView)
	}
	if view["monitor.interval"] != "30" {
		t.Errorf("非敏感默认值应直接可见: %v", view["monitor.interval"])
	}
}

// env 吸收：MONITOR_INTERVAL / PUSHPLUS_TOKEN 首启原值入库（secret 加密）。
func TestLoadAbsorbsEnv(t *testing.T) {
	t.Setenv("MONITOR_INTERVAL", "60")
	t.Setenv("PUSHPLUS_TOKEN", "token-abcd1234")
	s := newStore(t)
	if v, _, _ := s.Get("monitor.interval"); v != "60" {
		t.Errorf("env 吸收未生效: %q", v)
	}
	if v, _, _ := s.Get("pushplus.token"); v != "token-abcd1234" {
		t.Errorf("敏感 env 吸收未生效: %q", v)
	}

	var raw string
	if err := s.db.QueryRow(`SELECT value FROM settings WHERE key='pushplus.token'`).Scan(&raw); err != nil {
		t.Fatalf("查库: %v", err)
	}
	if raw == "token-abcd1234" || len(raw) < 20 {
		t.Errorf("敏感值应加密落库，实际 %q", raw)
	}
	if pt, err := crypto.Decrypt("test-master-key", raw); err != nil || pt != "token-abcd1234" {
		t.Errorf("密文应可用主密钥解开: %v", err)
	}
}

// jwt.secret：env 有则吸收，env 无则自动生成（64 位 hex）。
func TestJWTSecretBootstrap(t *testing.T) {
	t.Setenv("JWT_SECRET", "")
	s := newStore(t)
	v, ok, _ := s.Get("jwt.secret")
	if !ok || len(v) != 64 {
		t.Errorf("自动生成 jwt.secret 长度应 64: len=%d ok=%v", len(v), ok)
	}
	t.Setenv("JWT_SECRET", "env-provided-secret-1234567890")
	s2 := newStore(t)
	if v, _, _ := s2.Get("jwt.secret"); v != "env-provided-secret-1234567890" {
		t.Errorf("env 提供的 jwt.secret 应被吸收: %q", v)
	}
}

// 校验与 revision 自增。
func TestSetValidationAndRevision(t *testing.T) {
	s := newStore(t)
	rev0 := s.Rev()
	if err := s.Set(map[string]string{"monitor.interval": "0"}); err == nil {
		t.Error("非正数应被拒绝")
	}
	if err := s.Set(map[string]string{"nope.key": "x"}); err == nil {
		t.Error("未知 key 应被拒绝")
	}
	if err := s.Set(map[string]string{"revision": "999"}); err == nil {
		t.Error("revision 应禁止修改")
	}
	if err := s.Set(map[string]string{"monitor.interval": "abc"}); err == nil {
		t.Error("非整数应被拒绝")
	}
	if err := s.Set(map[string]string{"monitor.interval": "15", "compose.roots": "/srv/a,/srv/b"}); err != nil {
		t.Fatalf("合法更新失败: %v", err)
	}
	if s.Rev() != rev0+1 {
		t.Errorf("revision 应 +1: %d -> %d", rev0, s.Rev())
	}
	if v, _, _ := s.Get("monitor.interval"); v != "15" {
		t.Errorf("更新未生效: %q", v)
	}
	if v, _, _ := s.Get("compose.roots"); v != "/srv/a,/srv/b" {
		t.Errorf("CSV 更新未生效: %q", v)
	}
}

// 优先级：DB > env（吸收后 env 变更不再生效，直到 API 修改）。
func TestPriorityDBOverEnv(t *testing.T) {
	t.Setenv("MONITOR_INTERVAL", "60")
	s := newStore(t)
	t.Setenv("MONITOR_INTERVAL", "90") // 吸收后再改 env
	if v, _, _ := s.Get("monitor.interval"); v != "60" {
		t.Errorf("DB 应优先于 env: %q", v)
	}
	if err := s.Set(map[string]string{"monitor.interval": "45"}); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if v, _, _ := s.Get("monitor.interval"); v != "45" {
		t.Errorf("Set 后应为新值: %q", v)
	}
}

// 掩码视图：敏感值只回尾 4 位。
func TestMaskedTail4(t *testing.T) {
	t.Setenv("PUSHPLUS_TOKEN", "abcdefgh1234")
	s := newStore(t)
	view, _ := s.MaskedView()
	m := view["pushplus.token"].(map[string]any)
	if m["masked"] != "****1234" {
		t.Errorf("masked = %v, want ****1234", m["masked"])
	}
	if m["set"] != true {
		t.Errorf("已设置应为 true")
	}
}

// 热生效：外部改库（+revision）后 Get 轮询可见。
func TestHotReload(t *testing.T) {
	s := newStore(t)
	if _, err := s.db.Exec(`UPDATE settings SET value='99', updated_at=CURRENT_TIMESTAMP WHERE key='monitor.interval'`); err != nil {
		t.Fatalf("外部改库: %v", err)
	}
	if _, err := s.db.Exec(`UPDATE settings SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='revision'`); err != nil {
		t.Fatalf("bump revision: %v", err)
	}
	if v, _, _ := s.Get("monitor.interval"); v != "99" {
		t.Errorf("热生效未观测到外部变更: %q", v)
	}
}
