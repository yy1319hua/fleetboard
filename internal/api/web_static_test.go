package api

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// PWA 剥离兜底（M7.4 复盘）：/sw.js 恒返回自杀 SW；index 回退 no-cache。
func TestWebStaticSuicideSW(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<html>ok</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	gin.SetMode(gin.TestMode)
	r := gin.New()
	registerWebStatic(r, dir)

	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/sw.js", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), "unregister") {
		t.Fatalf("sw.js 应返回自杀 SW: %d %s", w.Code, w.Body.String())
	}
	if cc := w.Header().Get("Cache-Control"); cc != "no-cache" {
		t.Errorf("sw.js Cache-Control = %q", cc)
	}

	w = httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/some/route", nil))
	if cc := w.Header().Get("Cache-Control"); cc != "no-cache" {
		t.Errorf("index 回退 Cache-Control = %q", cc)
	}
	if !strings.Contains(w.Body.String(), "ok") {
		t.Errorf("index 应回退: %s", w.Body.String())
	}
}
