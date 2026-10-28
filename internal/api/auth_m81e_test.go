package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

// M8.1e 端到端：改密 → 旧会话（含 7 天 refresh）全吊销；当前会话拿新 token 对。
func TestChangePasswordRevokesOldSessions(t *testing.T) {
	r, _ := newSettingsTestServer(t)

	// 会话 A：稍后被改密踢掉
	oldTokens := loginTokens(t, r)
	// 会话 B：发起改密
	newTokens := loginTokens(t, r)

	// 旧密码错误 → 401
	w := settingsRequest(t, r, http.MethodPost, "/api/auth/change-password", map[string]string{
		"old_password": "wrong-pass", "new_password": "newpass123",
	}, newTokens.AccessToken)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("旧密码错误应 401: %d", w.Code)
	}

	// 正确改密 → 200 + 新 token 对
	w = settingsRequest(t, r, http.MethodPost, "/api/auth/change-password", map[string]string{
		"old_password": "pass123", "new_password": "newpass123",
	}, newTokens.AccessToken)
	if w.Code != http.StatusOK {
		t.Fatalf("改密失败: %d %s", w.Code, w.Body)
	}
	var resp struct {
		Data tokenResponse `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析: %v", err)
	}
	if resp.Data.AccessToken == "" || resp.Data.RefreshToken == "" {
		t.Fatalf("改密应返回新 token 对: %+v", resp.Data)
	}

	// 会话 A 的旧 access → 401
	w = settingsRequest(t, r, http.MethodGet, "/api/settings", nil, oldTokens.AccessToken)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("旧 access 应 401: %d", w.Code)
	}
	// 会话 A 的旧 refresh → 401（无状态 7 天 refresh 被吊销——本项核心判据）
	w = settingsRequest(t, r, http.MethodPost, "/api/refresh", map[string]string{
		"refresh_token": oldTokens.RefreshToken,
	}, "")
	if w.Code != http.StatusUnauthorized {
		t.Errorf("旧 refresh 应 401: %d", w.Code)
	}
	// 会话 B 的新 token 可用
	w = settingsRequest(t, r, http.MethodGet, "/api/settings", nil, resp.Data.AccessToken)
	if w.Code != http.StatusOK {
		t.Errorf("新 access 应 200: %d", w.Code)
	}

	// 新密码可登录
	w = settingsRequest(t, r, http.MethodPost, "/api/login", map[string]string{
		"username": "admin", "password": "newpass123",
	}, "")
	if w.Code != http.StatusOK {
		t.Errorf("新密码登录应 200: %d", w.Code)
	}
}

// revoke-sessions：ver 自增，旧 refresh 全灭。
func TestRevokeSessions(t *testing.T) {
	r, _ := newSettingsTestServer(t)
	tokens := loginTokens(t, r)

	w := settingsRequest(t, r, http.MethodPost, "/api/settings/actions/revoke-sessions", nil, tokens.AccessToken)
	if w.Code != http.StatusOK {
		t.Fatalf("revoke 失败: %d %s", w.Code, w.Body)
	}

	w = settingsRequest(t, r, http.MethodPost, "/api/refresh", map[string]string{
		"refresh_token": tokens.RefreshToken,
	}, "")
	if w.Code != http.StatusUnauthorized {
		t.Errorf("revoke 后旧 refresh 应 401: %d", w.Code)
	}
	w = settingsRequest(t, r, http.MethodGet, "/api/settings", nil, tokens.AccessToken)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("revoke 后旧 access 应 401: %d", w.Code)
	}
}

// 新密码过短 → 400。
func TestChangePasswordTooShort(t *testing.T) {
	r, _ := newSettingsTestServer(t)
	tokens := loginTokens(t, r)
	w := settingsRequest(t, r, http.MethodPost, "/api/auth/change-password", map[string]string{
		"old_password": "pass123", "new_password": "123",
	}, tokens.AccessToken)
	if w.Code != http.StatusBadRequest {
		t.Errorf("过短新密码应 400: %d", w.Code)
	}
}
