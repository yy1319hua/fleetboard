package api

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/settings"
)

// newIdentityTestServer 建一个带 DB 句柄的路由，供「改用户名」这类需要造数据的用例使用。
func newIdentityTestServer(t *testing.T) (*gin.Engine, *sql.DB) {
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
	return r, d
}

func meUsername(t *testing.T, r http.Handler, token string) string {
	t.Helper()
	w := settingsRequest(t, r, http.MethodGet, "/api/me", nil, token)
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/me status=%d body=%s", w.Code, w.Body)
	}
	var resp struct {
		Data struct {
			Username string `json:"username"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析 /api/me: %v", err)
	}
	return resp.Data.Username
}

// 改用户名：成功路径、/api/me 反映新名、旧 token 不失效。
func TestChangeUsernameSucceedsAndKeepsToken(t *testing.T) {
	r, _ := newIdentityTestServer(t)
	tokens := loginTokens(t, r)

	w := settingsRequest(t, r, http.MethodPost, "/api/auth/change-username",
		map[string]string{"new_username": "operator", "current_password": "pass123"}, tokens.AccessToken)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	if got := meUsername(t, r, tokens.AccessToken); got != "operator" {
		t.Fatalf("/api/me username=%q, want operator", got)
	}

	// 改名不动 token_ver：同一个 access token 必须继续可用（上面 /api/me 已证明）。
	// 这里再确认旧用户名登录失败、新用户名登录成功。
	if w := settingsRequest(t, r, http.MethodPost, "/api/login",
		map[string]string{"username": "admin", "password": "pass123"}, ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("旧用户名登录应 401，得到 %d", w.Code)
	}
	if w := settingsRequest(t, r, http.MethodPost, "/api/login",
		map[string]string{"username": "operator", "password": "pass123"}, ""); w.Code != http.StatusOK {
		t.Fatalf("新用户名登录应 200，得到 %d body=%s", w.Code, w.Body)
	}
}

func TestChangeUsernameRejects(t *testing.T) {
	r, _ := newIdentityTestServer(t)
	tokens := loginTokens(t, r)

	cases := []struct {
		name string
		body map[string]string
		want int
	}{
		{"密码错", map[string]string{"new_username": "operator", "current_password": "wrong"}, http.StatusUnauthorized},
		{"太短", map[string]string{"new_username": "ab", "current_password": "pass123"}, http.StatusBadRequest},
		{"非法字符", map[string]string{"new_username": "ad min", "current_password": "pass123"}, http.StatusBadRequest},
		{"中文", map[string]string{"new_username": "管理员", "current_password": "pass123"}, http.StatusBadRequest},
		{"数字开头可以", map[string]string{"new_username": "1abc", "current_password": "pass123"}, http.StatusOK},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := settingsRequest(t, r, http.MethodPost, "/api/auth/change-username", c.body, tokens.AccessToken)
			if w.Code != c.want {
				t.Fatalf("status=%d, want %d, body=%s", w.Code, c.want, w.Body)
			}
		})
	}
}

// 与当前用户名相同要明确报错，不能静默 200（否则用户以为改了）。
func TestChangeUsernameSameNameRejected(t *testing.T) {
	r, _ := newIdentityTestServer(t)
	tokens := loginTokens(t, r)
	w := settingsRequest(t, r, http.MethodPost, "/api/auth/change-username",
		map[string]string{"new_username": "admin", "current_password": "pass123"}, tokens.AccessToken)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400, body=%s", w.Code, w.Body)
	}
}

// 重名（含仅大小写不同）必须 409。
func TestChangeUsernameConflict(t *testing.T) {
	r, d := newIdentityTestServer(t)
	tokens := loginTokens(t, r)

	hash, err := auth.HashPassword("other123")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO users(username, password_hash) VALUES (?, ?)`, "taken", hash); err != nil {
		t.Fatalf("插入第二用户: %v", err)
	}

	for _, name := range []string{"taken", "TAKEN"} {
		w := settingsRequest(t, r, http.MethodPost, "/api/auth/change-username",
			map[string]string{"new_username": name, "current_password": "pass123"}, tokens.AccessToken)
		if w.Code != http.StatusConflict {
			t.Fatalf("%s 应 409，得到 %d body=%s", name, w.Code, w.Body)
		}
	}
}

// 告警规则 PUT：merge 语义，只传的字段变，其余保持。
func TestUpdateAlertRuleMergeSemantics(t *testing.T) {
	r, _ := newIdentityTestServer(t)
	tokens := loginTokens(t, r)

	w := settingsRequest(t, r, http.MethodPost, "/api/alert-rules", map[string]any{
		"metric": "cpu_pct", "operator": ">", "threshold": 80, "severity": "warn",
		"enabled": true, "notify_channels": "inapp,pushplus",
	}, tokens.AccessToken)
	if w.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", w.Code, w.Body)
	}
	var created struct {
		Data struct {
			ID int64 `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatalf("解析创建响应: %v", err)
	}
	rulePath := fmt.Sprintf("/api/alert-rules/%d", created.Data.ID)

	// 只改阈值
	w = settingsRequest(t, r, http.MethodPut, rulePath,
		map[string]any{"threshold": 90}, tokens.AccessToken)
	if w.Code != http.StatusOK {
		t.Fatalf("put status=%d body=%s", w.Code, w.Body)
	}
	var updated struct {
		Data struct {
			Threshold      float64 `json:"threshold"`
			Metric         string  `json:"metric"`
			Operator       string  `json:"operator"`
			Severity       string  `json:"severity"`
			Enabled        bool    `json:"enabled"`
			NotifyChannels string  `json:"notify_channels"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &updated); err != nil {
		t.Fatalf("解析更新响应: %v", err)
	}
	if updated.Data.Threshold != 90 {
		t.Errorf("threshold=%v, want 90", updated.Data.Threshold)
	}
	if updated.Data.Metric != "cpu_pct" || updated.Data.Operator != ">" ||
		updated.Data.Severity != "warn" || !updated.Data.Enabled ||
		updated.Data.NotifyChannels != "inapp,pushplus" {
		t.Errorf("未传字段被改动：%+v", updated.Data)
	}

	// 改归属必须被拒
	if w := settingsRequest(t, r, http.MethodPut, rulePath,
		map[string]any{"server_id": 3}, tokens.AccessToken); w.Code != http.StatusBadRequest {
		t.Fatalf("改 server_id 应 400，得到 %d", w.Code)
	}
	// 不存在
	if w := settingsRequest(t, r, http.MethodPut, "/api/alert-rules/999",
		map[string]any{"threshold": 50}, tokens.AccessToken); w.Code != http.StatusNotFound {
		t.Fatalf("不存在应 404，得到 %d", w.Code)
	}
	// 字段非法
	if w := settingsRequest(t, r, http.MethodPut, rulePath,
		map[string]any{"metric": "gpu_pct"}, tokens.AccessToken); w.Code != http.StatusBadRequest {
		t.Fatalf("非法 metric 应 400，得到 %d", w.Code)
	}
}
