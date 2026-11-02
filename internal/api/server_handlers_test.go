package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"golang.org/x/crypto/ssh"
)

func authReq(r http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, path, rd)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func TestCreateServerAPI(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name":        "vps1",
		"host":        "1.2.3.4",
		"auth_method": "key",
		"private_key": "SECRET-KEY-DATA",
	})
	if w.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	if bytes.Contains(w.Body.Bytes(), []byte("SECRET-KEY-DATA")) {
		t.Error("响应泄露了私钥")
	}
}

func TestCreateServerRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodPost, "/api/servers", "", map[string]any{"name": "x", "host": "x"})
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestCreateServerMissingFields(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{"name": "only-name"})
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestListServersAPI(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	if w := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken,
		map[string]any{"name": "a", "host": "a"}); w.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", w.Code)
	}

	w := authReq(r, http.MethodGet, "/api/servers", tokens.AccessToken, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Data) != 1 {
		t.Errorf("len=%d, want 1", len(resp.Data))
	}
}

func TestGetServerNotFoundAPI(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestDeleteServerAPI(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken,
		map[string]any{"name": "del", "host": "del"})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d body=%s", cw.Code, cw.Body)
	}

	dw := authReq(r, http.MethodDelete, "/api/servers/1", tokens.AccessToken, nil)
	if dw.Code != http.StatusOK {
		t.Fatalf("删除 status=%d body=%s", dw.Code, dw.Body)
	}

	gw := authReq(r, http.MethodGet, "/api/servers/1", tokens.AccessToken, nil)
	if gw.Code != http.StatusNotFound {
		t.Errorf("删除后 status=%d, want 404", gw.Code)
	}
}

func TestServerStatusOffline(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "probe", "host": "unreachable", "auth_method": "key", "private_key": "K",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d body=%s", cw.Code, cw.Body)
	}

	// 假 dialer 必然失败 → 502 且状态落 offline
	tw := authReq(r, http.MethodPost, "/api/servers/1/test", tokens.AccessToken, nil)
	if tw.Code != http.StatusBadGateway {
		t.Errorf("连接失败应 502，实际 status=%d body=%s", tw.Code, tw.Body)
	}

	gw := authReq(r, http.MethodGet, "/api/servers/1", tokens.AccessToken, nil)
	var resp struct {
		Data struct {
			ConnectionStatus string `json:"connection_status"`
		} `json:"data"`
	}
	if err := json.Unmarshal(gw.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Data.ConnectionStatus != "offline" {
		t.Errorf("connection_status=%q, want offline", resp.Data.ConnectionStatus)
	}
}

// ---------- 纳管预检（先测后存） ----------

// 预检失败必须零副作用：连不上的服务器不进列表，也不留半条记录。
func TestProbeServerFailurePersistsNothing(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/probe", tokens.AccessToken, map[string]any{
		"host": "192.0.2.99", "port": 22, "ssh_user": "root",
		"auth_method": "key", "private_key": "SECRET-K1",
	})
	if w.Code != http.StatusBadGateway {
		t.Fatalf("预检失败应 502，实际 status=%d body=%s", w.Code, w.Body)
	}

	lw := authReq(r, http.MethodGet, "/api/servers", tokens.AccessToken, nil)
	var list struct {
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(lw.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	if len(list.Data) != 0 {
		t.Errorf("预检失败后列表应有 0 条，实际 %d 条", len(list.Data))
	}
}

func TestProbeServerSuccess(t *testing.T) {
	r, d := newAuthTestServerWithDialer(t, func(context.Context, sshpool.Config) (*ssh.Client, error) {
		// 成功分支桩：nil client + nil error，Probe 内部判空后不 Close。
		return nil, nil
	})
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/probe", tokens.AccessToken, map[string]any{
		"host": "192.0.2.10", "auth_method": "key", "private_key": "K",
	})
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	var resp struct {
		Data struct {
			OK        bool  `json:"ok"`
			ElapsedMS int64 `json:"elapsed_ms"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if !resp.Data.OK {
		t.Error("data.ok 应为 true")
	}

	// 成功也不落库：登记由客户端在预检通过后显式 POST /api/servers 完成。
	lw := authReq(r, http.MethodGet, "/api/servers", tokens.AccessToken, nil)
	var list struct {
		Data []map[string]any `json:"data"`
	}
	_ = json.Unmarshal(lw.Body.Bytes(), &list)
	if len(list.Data) != 0 {
		t.Errorf("预检成功也不应自动登记，实际 %d 条", len(list.Data))
	}
}

// 编辑场景：凭据留空时，预检要用库里已存的值去连，而不是空凭据必失败。
func TestProbeServerReusesStoredCredential(t *testing.T) {
	var got sshpool.Config
	r, d := newAuthTestServerWithDialer(t, func(_ context.Context, cfg sshpool.Config) (*ssh.Client, error) {
		got = cfg
		return nil, nil
	})
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "amd1", "host": "192.0.2.1", "port": 2222, "ssh_user": "ai",
		"auth_method": "key", "private_key": "SECRET-K1", "key_pass": "PASS1",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d body=%s", cw.Code, cw.Body)
	}

	w := authReq(r, http.MethodPost, "/api/servers/probe", tokens.AccessToken, map[string]any{
		"server_id": 1, "host": "192.0.2.170",
	})
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	if got.Host != "192.0.2.170" {
		t.Errorf("host=%q, want 新填入的 192.0.2.170", got.Host)
	}
	if got.Port != 2222 || got.User != "ai" {
		t.Errorf("port/user=%d/%q, want 沿用 2222/ai", got.Port, got.User)
	}
	if got.PrivateKey != "SECRET-K1" || got.KeyPass != "PASS1" {
		t.Errorf("凭据未沿用库中原值：key=%q pass=%q", got.PrivateKey, got.KeyPass)
	}
}

// ---------- 编辑服务器 ----------

func TestUpdateServerKeepsCredentialWhenBlank(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	if cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "old", "host": "192.0.2.1", "auth_method": "key", "private_key": "SECRET-K1",
	}); cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d body=%s", cw.Code, cw.Body)
	}

	// 只改元信息，凭据字段全空 → 不修改。
	w := authReq(r, http.MethodPut, "/api/servers/1", tokens.AccessToken, map[string]any{
		"name": "renamed", "host": "192.0.2.9", "port": 2202, "ssh_user": "ai", "tags": "生产",
	})
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}

	var resp struct {
		Data struct {
			Name   string `json:"name"`
			Port   int    `json:"port"`
			Status string `json:"connection_status"`
			Heart  any    `json:"last_heartbeat"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Data.Name != "renamed" || resp.Data.Port != 2202 {
		t.Errorf("元信息未更新：name=%q port=%d", resp.Data.Name, resp.Data.Port)
	}
	if resp.Data.Status != "unknown" {
		t.Errorf("connection_status=%q, want unknown（旧结论已不可信）", resp.Data.Status)
	}
	if resp.Data.Heart != nil {
		t.Errorf("last_heartbeat 不应被改配置刷成当前时间，实际 %v", resp.Data.Heart)
	}

	cred, err := db.GetDecryptedCredential(d, "test-master", 1)
	if err != nil {
		t.Fatal(err)
	}
	if cred.AuthMethod != "key" || cred.PrivateKey != "SECRET-K1" {
		t.Errorf("凭据被清空：method=%q key=%q", cred.AuthMethod, cred.PrivateKey)
	}
	if cred.Password != "" {
		t.Errorf("密码字段应为空，实际 %q", cred.Password)
	}
}

func TestUpdateServerSwitchAuthMethod(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	if cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "sw", "host": "h", "auth_method": "key", "private_key": "K1",
	}); cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	w := authReq(r, http.MethodPut, "/api/servers/1", tokens.AccessToken, map[string]any{
		"name": "sw", "host": "h", "auth_method": "password", "password": "newpass",
	})
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}

	cred, err := db.GetDecryptedCredential(d, "test-master", 1)
	if err != nil {
		t.Fatal(err)
	}
	if cred.AuthMethod != "password" || cred.Password != "newpass" {
		t.Errorf("切换失败：method=%q pass=%q", cred.AuthMethod, cred.Password)
	}
	if cred.PrivateKey != "" {
		t.Errorf("切到密码后私钥应清空，实际残留 %q", cred.PrivateKey)
	}
}

func TestUpdateServerRejectsSwitchWithoutCredential(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	if cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "h", "auth_method": "key", "private_key": "K1",
	}); cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	w := authReq(r, http.MethodPut, "/api/servers/1", tokens.AccessToken, map[string]any{
		"name": "x", "host": "h", "auth_method": "password",
	})
	if w.Code != http.StatusBadRequest {
		t.Errorf("切换认证方式却无密码应 400，实际 status=%d body=%s", w.Code, w.Body)
	}
}

func TestUpdateServerValidation(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	if cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "v", "host": "h", "auth_method": "key", "private_key": "K",
	}); cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	cases := []struct {
		name string
		body map[string]any
		want int
	}{
		{"端口越界", map[string]any{"name": "v", "host": "h", "port": 70000}, http.StatusBadRequest},
		{"名称清空", map[string]any{"name": "", "host": "h"}, http.StatusBadRequest},
	}
	for _, tc := range cases {
		w := authReq(r, http.MethodPut, "/api/servers/1", tokens.AccessToken, tc.body)
		if w.Code != tc.want {
			t.Errorf("%s：status=%d, want %d body=%s", tc.name, w.Code, tc.want, w.Body)
		}
	}

	w := authReq(r, http.MethodPut, "/api/servers/999", tokens.AccessToken,
		map[string]any{"name": "n", "host": "h"})
	if w.Code != http.StatusNotFound {
		t.Errorf("不存在的服务器应 404，实际 status=%d", w.Code)
	}
}
