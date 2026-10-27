package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync/atomic"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/pkg"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// errPackageUpdate 是对外统一文案：原始错误只进服务端日志，不回传客户端。
const errPackageUpdate = "软件包更新失败，请查看服务端日志"

// sseFrame 把负载编码为一个 SSE 数据帧（`data: <json>\n\n`）。
func sseFrame(payload gin.H) (string, error) {
	b, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("data: %s\n\n", b), nil
}

// packageUpdateHandler 以 SSE 流式回传 apt 更新进度，支持取消。
// POST /api/servers/:id/packages/update
//
// 取消方式：客户端直接 abort 请求（浏览器 fetch AbortController）→ 请求上下文取消
// → 向远端 apt 发送 SIGINT 并关闭会话。前端用 fetch + ReadableStream 读取，
// 因此可携带 Authorization 头，token 不必进 URL。
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

		ctx, cancel := context.WithCancel(c.Request.Context())
		defer cancel()

		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("Connection", "keep-alive")
		c.Header("X-Accel-Buffering", "no") // 关闭反代缓冲，保证逐行可见
		c.Status(http.StatusOK)

		flusher, _ := c.Writer.(http.Flusher)
		var writeFailed atomic.Bool

		send := func(payload gin.H) {
			if writeFailed.Load() {
				return
			}
			frame, mErr := sseFrame(payload)
			if mErr != nil {
				return
			}
			if _, wErr := c.Writer.WriteString(frame); wErr != nil {
				// 客户端已断开：标记并取消，尽快停掉远端 apt
				writeFailed.Store(true)
				cancel()
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}

		send(gin.H{"event": "started", "message": "开始更新软件包"})

		runErr := pkg.Upgrade(ctx, cli, func(line string) {
			send(gin.H{"event": "line", "line": line})
		})

		result := "ok"
		switch {
		case runErr == nil:
			send(gin.H{"event": "done", "ok": true})
		case ctx.Err() != nil:
			// 客户端断开或上下文取消 → 视为已取消
			result = "canceled"
			send(gin.H{"event": "done", "ok": false, "canceled": true})
		default:
			result = "fail"
			log.Printf("apt 更新（server #%d）失败: %v", id, runErr)
			send(gin.H{"event": "done", "ok": false, "error": errPackageUpdate})
		}

		sid := id
		_ = db.InsertAudit(d, CurrentUserID(c), &sid, "packages.update", "apt-get update && upgrade -y", result)
	}
}
