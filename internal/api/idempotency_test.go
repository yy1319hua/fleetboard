package api

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

// newIdempotencyTestEngine 起一个最小引擎：一条动作路由 + 计数器，
// 用来观察「业务到底被执行了几次」——这是幂等中间件唯一的判据。
func newIdempotencyTestEngine(ttl time.Duration, executed *int32) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	// 模拟 JWTAuth 注入的 uid，幂等键依赖它
	r.Use(func(c *gin.Context) {
		c.Set(ctxUserID, int64(1))
		c.Next()
	})
	r.POST("/api/servers/:id/actions", Idempotency(ttl), func(c *gin.Context) {
		n := atomic.AddInt32(executed, 1)
		c.JSON(http.StatusOK, Response{Code: CodeOK, Msg: "ok", Data: gin.H{"run": n}})
	})
	return r
}

func idemRequest(r http.Handler, opID string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/api/servers/12/actions", nil)
	req.Header.Set("Content-Type", "application/json")
	if opID != "" {
		req.Header.Set(idempotencyHeader, opID)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// 同键重复请求只执行业务一次，且回放首次的 status + body。
func TestIdempotencyReplaysOnce(t *testing.T) {
	var executed int32
	r := newIdempotencyTestEngine(time.Minute, &executed)

	first := idemRequest(r, "op-abc")
	second := idemRequest(r, "op-abc")

	if n := atomic.LoadInt32(&executed); n != 1 {
		t.Fatalf("业务执行 %d 次, want 1", n)
	}
	if second.Code != first.Code {
		t.Errorf("回放状态码=%d, want %d", second.Code, first.Code)
	}
	if second.Body.String() != first.Body.String() {
		t.Errorf("回放响应体不一致:\n first=%s\n second=%s", first.Body, second.Body)
	}
	if second.Header().Get("X-Idempotent-Replay") != "true" {
		t.Error("回放响应应带 X-Idempotent-Replay 便于排查")
	}

	// 不同 opId = 不同操作，必须真的执行
	_ = idemRequest(r, "op-other")
	if n := atomic.LoadInt32(&executed); n != 2 {
		t.Errorf("换 opId 后应执行, 实际 %d 次", n)
	}
}

// 没有 X-Client-Op-Id 的请求完全放行（老客户端与 Web 不受影响）。
func TestIdempotencyNoOpIDPassThrough(t *testing.T) {
	var executed int32
	r := newIdempotencyTestEngine(time.Minute, &executed)

	for i := 0; i < 2; i++ {
		w := idemRequest(r, "")
		if w.Header().Get("X-Idempotent-Replay") != "" {
			t.Error("无 opId 不应命中回放")
		}
	}
	if n := atomic.LoadInt32(&executed); n != 2 {
		t.Errorf("业务执行 %d 次, want 2（无头不缓存）", n)
	}
}

// 过期后同键可再次执行。
func TestIdempotencyExpiry(t *testing.T) {
	var executed int32
	r := newIdempotencyTestEngine(20*time.Millisecond, &executed)

	_ = idemRequest(r, "op-ttl")
	_ = idemRequest(r, "op-ttl")
	if n := atomic.LoadInt32(&executed); n != 1 {
		t.Fatalf("窗口内应只执行 1 次, 实际 %d", n)
	}

	// 等窗口过期：TTL 只有 20ms，这里等 40ms 足够且不会拖慢测试
	time.Sleep(40 * time.Millisecond)

	_ = idemRequest(r, "op-ttl")
	if n := atomic.LoadInt32(&executed); n != 2 {
		t.Errorf("过期后应重新执行, 实际 %d 次", n)
	}
}

// key 必须带 uid 与路由模板：跨用户/跨路由的同 opId 不能互相回放。
func TestIdempotencyKeyScope(t *testing.T) {
	base := idempotencyKey(1, http.MethodPost, "/api/servers/:id/actions", "op")
	if base == idempotencyKey(2, http.MethodPost, "/api/servers/:id/actions", "op") {
		t.Error("不同用户不应共享幂等键")
	}
	if base == idempotencyKey(1, http.MethodPost, "/api/servers/:id/compose/actions", "op") {
		t.Error("不同路由不应共享幂等键")
	}
}
