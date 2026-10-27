package api

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
)

func newAuthTestServer(t *testing.T) (*gin.Engine, *sql.DB) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	if _, err := db.EnsureAdmin(d, "admin", "pass123"); err != nil {
		t.Fatalf("EnsureAdmin: %v", err)
	}
	gin.SetMode(gin.TestMode)
	r := NewRouter(RouterOptions{DB: d, JWTSecret: "test-secret", MasterKey: "test-master"})
	return r, d
}

func postJSON(r http.Handler, path string, body any) *httptest.ResponseRecorder {
	b, _ := json.Marshal(body)
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	r.ServeHTTP(w, req)
	return w
}

func loginTokens(t *testing.T, r http.Handler) tokenResponse {
	t.Helper()
	w := postJSON(r, "/api/login", map[string]string{"username": "admin", "password": "pass123"})
	if w.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", w.Code, w.Body)
	}
	var resp struct {
		Data tokenResponse `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析登录响应: %v", err)
	}
	return resp.Data
}

func TestLoginSuccess(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	tokens := loginTokens(t, r)
	if tokens.AccessToken == "" || tokens.RefreshToken == "" {
		t.Errorf("应返回双 token，实际 %+v", tokens)
	}
	if tokens.ExpiresIn != int(15*60) {
		t.Errorf("ExpiresIn=%d", tokens.ExpiresIn)
	}
}

func TestLoginWrongPassword(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := postJSON(r, "/api/login", map[string]string{"username": "admin", "password": "wrong"})
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestLoginUnknownUser(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := postJSON(r, "/api/login", map[string]string{"username": "ghost", "password": "x"})
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestMeRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/me", nil))
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestMeWithToken(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	tokens := loginTokens(t, r)
	req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	req.Header.Set("Authorization", "Bearer "+tokens.AccessToken)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
}

func TestRefresh(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	tokens := loginTokens(t, r)
	w := postJSON(r, "/api/refresh", map[string]string{"refresh_token": tokens.RefreshToken})
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
}

func TestRefreshRejectsAccessToken(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	tokens := loginTokens(t, r)
	w := postJSON(r, "/api/refresh", map[string]string{"refresh_token": tokens.AccessToken})
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}
