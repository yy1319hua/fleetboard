package api

import (
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestSSEFrameFormat(t *testing.T) {
	frame, err := sseFrame(gin.H{"event": "line", "line": "Reading package lists..."})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(frame, "data: {") {
		t.Errorf("帧应以 `data: {` 开头，实际 %q", frame)
	}
	if !strings.HasSuffix(frame, "\n\n") {
		t.Errorf("帧应以空行结束，实际 %q", frame)
	}
	if strings.Count(frame, "\n") != 2 {
		t.Errorf("单帧应只含两个换行，实际 %q", frame)
	}
	if !strings.Contains(frame, `"event":"line"`) {
		t.Errorf("帧内应为紧凑 JSON，实际 %q", frame)
	}
}

func TestSSEFrameRejectsUnserializable(t *testing.T) {
	// 函数值无法 JSON 序列化 → 应返回错误而不是静默产出坏帧
	if _, err := sseFrame(gin.H{"bad": func() {}}); err == nil {
		t.Error("不可序列化负载应报错")
	}
}

func TestPackageUpdateRequiresAuth(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()

	w := authReq(r, http.MethodPost, "/api/servers/1/packages/update", "", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status=%d, want 401", w.Code)
	}
}

func TestPackageUpdateServerNotFound(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	w := authReq(r, http.MethodPost, "/api/servers/999/packages/update", tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status=%d, want 404", w.Code)
	}
}

func TestPackageUpdateConnectionError(t *testing.T) {
	r, d := newAuthTestServer(t)
	defer d.Close()
	tokens := loginTokens(t, r)

	cw := authReq(r, http.MethodPost, "/api/servers", tokens.AccessToken, map[string]any{
		"name": "x", "host": "unreachable", "auth_method": "key", "private_key": "K",
	})
	if cw.Code != http.StatusCreated {
		t.Fatalf("创建失败 status=%d", cw.Code)
	}

	// SSH 连不上时流尚未开始，应返回 JSON 502 而非 SSE
	w := authReq(r, http.MethodPost, "/api/servers/1/packages/update", tokens.AccessToken, nil)
	if w.Code != http.StatusBadGateway {
		t.Errorf("status=%d, want 502 body=%s", w.Code, w.Body)
	}
	if ct := w.Header().Get("Content-Type"); ct != "" && ct != "application/json; charset=utf-8" {
		t.Errorf("连接失败时不应是事件流，Content-Type=%q", ct)
	}
}
