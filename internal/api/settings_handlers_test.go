package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/settings"
)

func newSettingsTestServer(t *testing.T) (*gin.Engine, *settings.Store) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if _, err := db.EnsureAdmin(d, "admin", "pass123"); err != nil {
		t.Fatalf("EnsureAdmin: %v", err)
	}
	st, err := settings.Load(d, "test-master-key")
	if err != nil {
		t.Fatalf("settings.Load: %v", err)
	}
	gin.SetMode(gin.TestMode)
	r := NewRouter(RouterOptions{
		DB:        d,
		JWTSecret: "test-secret",
		MasterKey: "test-master",
		Settings:  st,
		Port:      8080,
	})
	return r, st
}

func settingsRequest(t *testing.T, r http.Handler, method, path string, body any, token string) *httptest.ResponseRecorder {
	t.Helper()
	var req *http.Request
	if body != nil {
		b, _ := json.Marshal(body)
		req = httptest.NewRequest(method, path, bytes.NewReader(b))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// GET：非敏感项直接可见；敏感项只回掩码。
func TestSettingsGetMasked(t *testing.T) {
	r, _ := newSettingsTestServer(t)
	tokens := loginTokens(t, r)
	w := settingsRequest(t, r, http.MethodGet, "/api/settings", nil, tokens.AccessToken)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	var resp struct {
		Data struct {
			Items    map[string]any `json:"items"`
			Readonly map[string]any `json:"readonly"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析: %v", err)
	}
	if resp.Data.Readonly["key_masked"] != "****ster" || resp.Data.Readonly["port"] != float64(8080) {
		t.Errorf("只读区应含 KEY 尾4位与端口: %v", resp.Data.Readonly)
	}
	if resp.Data.Items["monitor.interval"] != "30" {
		t.Errorf("非敏感默认应可见: %v", resp.Data.Items["monitor.interval"])
	}
	m, ok := resp.Data.Items["pushplus.token"].(map[string]any)
	if !ok || m["set"] != false {
		t.Errorf("敏感未设项应 {set:false}: %v", resp.Data.Items["pushplus.token"])
	}
}

// PUT 往返：改值生效；掩码回写不生效；敏感值落库为密文。
func TestSettingsPutRoundTrip(t *testing.T) {
	r, st := newSettingsTestServer(t)
	tokens := loginTokens(t, r)

	w := settingsRequest(t, r, http.MethodPut, "/api/settings", map[string]any{
		"monitor.interval": "15",
		"pushplus.token":   "token-abcd1234",
	}, tokens.AccessToken)
	if w.Code != http.StatusOK {
		t.Fatalf("PUT status=%d body=%s", w.Code, w.Body)
	}
	if v, _, _ := st.Get("monitor.interval"); v != "15" {
		t.Errorf("monitor.interval 未生效: %q", v)
	}
	if v, _, _ := st.Get("pushplus.token"); v != "token-abcd1234" {
		t.Errorf("pushplus.token 未生效: %q", v)
	}
	var resp struct {
		Data struct {
			Items map[string]any `json:"items"`
		} `json:"data"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	m := resp.Data.Items["pushplus.token"].(map[string]any)
	if m["masked"] != "****1234" {
		t.Errorf("GET 视图应只回掩码: %v", m)
	}

	// 掩码回写：不修改值
	w = settingsRequest(t, r, http.MethodPut, "/api/settings", map[string]any{
		"pushplus.token": "****1234",
	}, tokens.AccessToken)
	if w.Code != http.StatusOK {
		t.Fatalf("掩码回写 status=%d", w.Code)
	}
	if v, _, _ := st.Get("pushplus.token"); v != "token-abcd1234" {
		t.Errorf("掩码回写不应改变值: %q", v)
	}

	// 落库必须是密文
	d := st.DB()
	var raw string
	if err := d.QueryRow(`SELECT value FROM settings WHERE key='pushplus.token'`).Scan(&raw); err != nil {
		t.Fatalf("查库: %v", err)
	}
	if raw == "token-abcd1234" || len(raw) < 20 {
		t.Errorf("敏感值应加密落库: %q", raw)
	}
}

// PUT 校验：非法值 400 且整批拒绝。
func TestSettingsPutValidation(t *testing.T) {
	r, st := newSettingsTestServer(t)
	tokens := loginTokens(t, r)
	cases := []struct {
		name string
		body map[string]any
	}{
		{"未知 key", map[string]any{"nope.key": "1"}},
		{"非法整数", map[string]any{"monitor.interval": "0"}},
		{"非法 CSV", map[string]any{"compose.roots": "a,,b"}},
		{"revision 禁改", map[string]any{"revision": "999"}},
		{"混合批任一非法", map[string]any{"monitor.interval": "20", "nope": "x"}},
	}
	for _, c := range cases {
		w := settingsRequest(t, r, http.MethodPut, "/api/settings", c.body, tokens.AccessToken)
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s: status=%d, want 400", c.name, w.Code)
		}
	}
	if v, _, _ := st.Get("monitor.interval"); v != "30" {
		t.Errorf("整批拒绝后不应有部分生效: %q", v)
	}
}

// 鉴权：无 token 401。
func TestSettingsUnauthorized(t *testing.T) {
	r, _ := newSettingsTestServer(t)
	w := settingsRequest(t, r, http.MethodGet, "/api/settings", nil, "")
	if w.Code != http.StatusUnauthorized {
		t.Errorf("未带 token: status=%d, want 401", w.Code)
	}
	w = settingsRequest(t, r, http.MethodPut, "/api/settings", map[string]any{"monitor.interval": "20"}, "")
	if w.Code != http.StatusUnauthorized {
		t.Errorf("未带 token PUT: status=%d, want 401", w.Code)
	}
}

// nil store：500，不 panic。
func TestSettingsNilStore500(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	defer d.Close()
	if _, err := db.EnsureAdmin(d, "admin", "pass123"); err != nil {
		t.Fatalf("EnsureAdmin: %v", err)
	}
	gin.SetMode(gin.TestMode)
	r := NewRouter(RouterOptions{DB: d, JWTSecret: "s", MasterKey: "k"})
	tokens := loginTokens(t, r)
	w := settingsRequest(t, r, http.MethodGet, "/api/settings", nil, tokens.AccessToken)
	if w.Code != http.StatusInternalServerError {
		t.Errorf("nil store: status=%d, want 500", w.Code)
	}
}
