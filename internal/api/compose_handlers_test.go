package api

import (
	"net/http"
	"testing"
)

func TestListComposeRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/compose", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestListComposeServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/compose", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestListComposePathDenied(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	// 白名单外的目录应在建立连接前就被拒（400），不应尝试 SSH
	w := authReq(r, http.MethodGet, "/api/servers/1/compose?dir=/var/log", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400 body=%s", w.Code, w.Body)
	}
}

func TestGetComposeContentRequiresPath(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/1/compose/content", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestGetComposeContentPathDenied(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/1/compose/content?path=/var/lib/passwd", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400 body=%s", w.Code, w.Body)
	}
}

func TestListComposeConnectionError(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "unreachable", "auth_method": "key", "private_key": "K",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	w := authReq(r, http.MethodGet, "/api/servers/1/compose?dir=/root", tokens.AccessToken, nil)
	if w.Code != http.StatusBadGateway {
		t.Errorf("status=%d, want 502 body=%s", w.Code, w.Body)
	}
}
