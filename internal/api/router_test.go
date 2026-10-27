package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestHealth(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := NewRouter(RouterOptions{Version: "test", Schema: "0001_init.sql"})

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/health", nil))

	if w.Code != http.StatusOK {
		t.Fatalf("status=%d, want 200", w.Code)
	}

	var resp struct {
		Code int            `json:"code"`
		Msg  string         `json:"msg"`
		Data map[string]any `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应: %v", err)
	}
	if resp.Code != CodeOK {
		t.Errorf("code=%d, want %d", resp.Code, CodeOK)
	}
	if resp.Data["status"] != "ok" {
		t.Errorf("data.status=%v", resp.Data["status"])
	}
	if resp.Data["version"] != "test" {
		t.Errorf("data.version=%v", resp.Data["version"])
	}
	if resp.Data["schema"] != "0001_init.sql" {
		t.Errorf("data.schema=%v", resp.Data["schema"])
	}
}

func TestUnknownRouteNotFound(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := NewRouter(RouterOptions{})

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/nope", nil))

	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}
