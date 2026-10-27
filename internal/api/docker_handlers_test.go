package api

import (
	"net/http"
	"testing"
)

func TestListContainersRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/containers", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestListContainersServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/containers", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestListContainersConnectionError(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "unreachable", "auth_method": "key", "private_key": "K",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	w := authReq(r, http.MethodGet, "/api/servers/1/containers", tokens.AccessToken, nil)
	if w.Code != http.StatusBadGateway {
		t.Errorf("status=%d, want 502 body=%s", w.Code, w.Body)
	}
}
