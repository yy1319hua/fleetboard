package api

import (
	"net/http"
	"testing"
)

func TestListFilesServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/files?path=/", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestListFilesRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodGet, "/api/servers/1/files", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestListFilesConnectionError(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "unreachable", "auth_method": "key", "private_key": "K",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	// 假 dialer 必然失败 → 502
	w := authReq(r, http.MethodGet, "/api/servers/1/files?path=/", tokens.AccessToken, nil)
	if w.Code != http.StatusBadGateway {
		t.Errorf("status=%d, want 502 body=%s", w.Code, w.Body)
	}
}

func TestDownloadRequiresPath(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/1/files/download", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestUploadRequiresPath(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/files/upload", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestDownloadServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/files/download?path=/x", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}
