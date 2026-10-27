package api

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/pkg"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// packageUpdateHandler 以 SSE 流式回传 apt 更新进度。
// POST /api/servers/:id/packages/update
// 前端用 fetch + ReadableStream 读取（可携带 Authorization 头，避免 token 进 URL）。
func packageUpdateHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		// 连接失败属于"流开始前"的错误，仍用统一 JSON 响应（502）
		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}

		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("Connection", "keep-alive")
		c.Header("X-Accel-Buffering", "no") // 关闭反代缓冲，保证逐行可见
		c.Status(http.StatusOK)

		flusher, _ := c.Writer.(http.Flusher)
		send := func(payload gin.H) error {
			b, mErr := json.Marshal(payload)
			if mErr != nil {
				return mErr
			}
			if _, wErr := fmt.Fprintf(c.Writer, "data: %s\n\n", b); wErr != nil {
				return wErr
			}
			if flusher != nil {
				flusher.Flush()
			}
			return nil
		}

		_ = send(gin.H{"event": "started", "message": "开始更新软件包"})

		err = pkg.Upgrade(c.Request.Context(), cli, func(line string) {
			_ = send(gin.H{"event": "line", "line": line})
		})
		if err != nil {
			log.Printf("apt 更新（server #%d）失败: %v", id, err)
		}
	}
}
