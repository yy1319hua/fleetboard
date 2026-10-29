package api

import (
	"bytes"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// idempotencyHeader 是客户端生成的操作唯一 ID（与审计的 opId 同源）。
const idempotencyHeader = "X-Client-Op-Id"

// Idempotency 对带 X-Client-Op-Id 的写请求做「同键短时回放」：
// 键 = (uid, method, FullPath, opId)，TTL 内重复请求直接回放首次的 <status, body>，
// 不再执行业务。用于兜住 App 弱网重试/用户连点导致的重复副作用（重复重启容器等）。
//
// 设计取舍：
//   - 只缓存已完成响应，不做「进行中」排队：容器动作本身秒级返回，排队化会引入
//     超时语义与 goroutine 生命周期管理，收益不值。
//   - 5xx 不缓存：服务端错误多为瞬时（SSH 抖动），回放会让重试永远拿到同一个失败。
//   - 无该头则完全放行：老客户端与 Web 未改造前不受影响。
func Idempotency(ttl time.Duration) gin.HandlerFunc {
	store := &idempotencyStore{entries: map[string]idempotencyEntry{}, ttl: ttl}
	return func(c *gin.Context) {
		opID := c.GetHeader(idempotencyHeader)
		if opID == "" {
			c.Next()
			return
		}
		// FullPath 用路由模板而非真实 URL：/servers/1/... 与 /servers/2/... 才会
		// 落到同一个键空间，opId 的碰撞检测由此真正生效。
		key := idempotencyKey(CurrentUserID(c), c.Request.Method, c.FullPath(), opID)
		if e, ok := store.get(key); ok {
			c.Header("X-Idempotent-Replay", "true")
			c.Data(e.status, e.contentType, e.body)
			c.Abort()
			return
		}

		rec := &bodyRecorder{ResponseWriter: c.Writer, body: &bytes.Buffer{}}
		c.Writer = rec
		c.Next()

		status := rec.Status()
		if status >= http.StatusInternalServerError {
			return // 瞬时失败不留档，允许客户端立刻重试
		}
		store.put(key, idempotencyEntry{
			status:      status,
			contentType: rec.Header().Get("Content-Type"),
			body:        append([]byte(nil), rec.body.Bytes()...),
		})
	}
}

// idempotencyKey 拼装幂等键；uid 入键保证跨用户同 opId 不会互相回放。
func idempotencyKey(uid int64, method, fullPath, opID string) string {
	return strconv.FormatInt(uid, 10) + "|" + method + "|" + fullPath + "|" + opID
}

type idempotencyEntry struct {
	status      int
	contentType string
	body        []byte
	exp         time.Time
}

// idempotencyStore 是带惰性清理的内存缓存（不引入 Redis 等新依赖）。
type idempotencyStore struct {
	mu      sync.Mutex
	entries map[string]idempotencyEntry
	ttl     time.Duration
}

func (s *idempotencyStore) get(key string) (idempotencyEntry, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	e, ok := s.entries[key]
	if !ok {
		return idempotencyEntry{}, false
	}
	if time.Now().After(e.exp) {
		delete(s.entries, key)
		return idempotencyEntry{}, false
	}
	return e, true
}

func (s *idempotencyStore) put(key string, e idempotencyEntry) {
	e.exp = time.Now().Add(s.ttl)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.entries[key] = e
	// 惰性清理：每次写入顺手扫一遍过期项。写频率与动作接口同量级（人工操作），
	// 全量扫描的成本可以忽略，也就省掉了独立的后台清理 goroutine。
	for k, v := range s.entries {
		if time.Now().After(v.exp) {
			delete(s.entries, k)
		}
	}
}

// bodyRecorder 记录响应体副本，供首次请求结束后写入幂等缓存。
type bodyRecorder struct {
	gin.ResponseWriter
	body *bytes.Buffer
}

func (r *bodyRecorder) Write(b []byte) (int, error) {
	r.body.Write(b)
	return r.ResponseWriter.Write(b)
}

func (r *bodyRecorder) WriteString(s string) (int, error) {
	r.body.WriteString(s)
	return r.ResponseWriter.WriteString(s)
}
