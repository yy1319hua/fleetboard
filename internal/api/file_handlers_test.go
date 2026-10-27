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

func TestGetContentRequiresPath(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/1/files/content", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestPutContentRequiresPath(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPut, "/api/servers/1/files/content", tokens.AccessToken,
		map[string]any{"content": "x"})
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestPutContentBadBody(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPut, "/api/servers/1/files/content?path=/x", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestGetContentServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/files/content?path=/x", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestRenameRequiresBody(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/files/rename", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestCopyRequiresBody(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/1/files/copy", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestDeleteRequiresPath(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodDelete, "/api/servers/1/files", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestDeleteServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodDelete, "/api/servers/999/files?path=/x", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestStatRequiresPath(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/1/files/stat", tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("status=%d, want 400", w.Code)
	}
}

func TestStatServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodGet, "/api/servers/999/files/stat?path=/x", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}
