package api

import (
	"log"
	"time"

	"github.com/gin-gonic/gin"
)

// slowRequestThreshold 是「慢请求」判定线：超过它或状态码 ≥500 才写日志。
const slowRequestThreshold = 3 * time.Second

// slowRequestLogger 只记录「慢」和「出错」的请求。
//
// 排查网关 502 时最缺的是「请求到底有没有进来、卡了多久」：gin 默认不带访问日志，
// 一个静默十几秒的请求在 journald 里不留任何痕迹，事后只能靠推断。
// 只记异常请求，正常流量不产生日志噪声。
func slowRequestLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()

		elapsed := time.Since(start)
		status := c.Writer.Status()
		if status < 500 && elapsed < slowRequestThreshold {
			return
		}

		uri := c.Request.URL.RequestURI()
		if len(uri) > 200 {
			uri = uri[:200] + "..."
		}
		log.Printf("[http] %s %s -> %d in %s", c.Request.Method, uri, status, elapsed.Round(time.Millisecond))
	}
}
