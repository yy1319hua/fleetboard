package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
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
