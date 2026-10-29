package api

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

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

// packageUpdateHandler 以「双通道」方式触发软件包升级：
//   - 立即返回 202 Accepted + Location: /api/jobs/:id + body {jobId, status:"running"}；
//   - 同时本请求保持 SSE 实时输出随本次连接流式推进（现状 SSE 不变）。
//
// 后台 goroutine 跑既有 pkg.Upgrade，其 ctx 以 context.Background() 派生（非请求 ctx），
// 因此 App 断连后升级仍可跑完，供 GET /api/jobs/:id 续接。SSE 断连仅 detach（不取消底层升级）；
// 显式取消走 DELETE /api/jobs/:id。
// POST /api/servers/:id/packages/update
func packageUpdateHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		// 流开始前连接失败：返回 JSON 502（保持原有契约，TestPackageUpdateConnectionError）
		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}

		uid := CurrentUserID(c)
		opID := c.GetHeader("X-Client-Op-Id")
		job := jobStore.CreateWithOp(opID, "packages.update", id, uid)

		// 双通道：立即 202 + Location，同时本请求保持 SSE 随进度流式推进。
		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("Connection", "keep-alive")
		c.Header("X-Accel-Buffering", "no") // 关闭反代缓冲，保证逐行可见
		c.Header("Location", "/api/jobs/"+job.JobID)
		c.Status(http.StatusAccepted) // 202

		flusher, _ := c.Writer.(http.Flusher)
		var writeFailed atomic.Bool
		var detached atomic.Bool
		var writeMu sync.Mutex

		// writeRaw 向 SSE 通道写一段原始文本（已含换行），统一走 detached / writeFailed 门闩。
		//
		// 心跳注释帧与数据帧必须共用同一把锁：绕过它并发写会在连接里产生
		// 交错的半帧，客户端解析直接坏掉。
		writeRaw := func(s string) bool {
			if writeFailed.Load() || detached.Load() {
				return false
			}
			writeMu.Lock()
			defer writeMu.Unlock()
			if _, wErr := c.Writer.WriteString(s); wErr != nil {
				writeFailed.Store(true)
				return false
			}
			if flusher != nil {
				flusher.Flush()
			}
			return true
		}

		// send 向本请求的 SSE 写一帧；客户端断开或 detach 后变为 no-op。
		send := func(payload gin.H) {
			if writeFailed.Load() || detached.Load() {
				return
			}
			frame, mErr := sseFrame(payload)
			if mErr != nil {
				return
			}
			writeRaw(frame)
		}

		// 发送 202 响应头 + 首帧（先于后台 goroutine，避免与后续 send 竞争）
		c.Writer.WriteHeaderNow()
		if flusher != nil {
			flusher.Flush()
		}
		send(gin.H{"event": "started", "message": "开始更新软件包", "jobId": job.JobID})

		// 后台跑升级：job ctx 独立于请求 ctx（context.Background 派生）。
		go func() {
			runErr := pkg.Upgrade(job.Context(), cli, func(line string) {
				job.AppendLine(line)
				send(gin.H{"event": "line", "line": line})
			})

			switch {
			case runErr == nil:
				job.finish(JobDone, "")
				send(gin.H{"event": "done", "ok": true})
			case job.Context().Err() != nil:
				// 显式取消（DELETE /api/jobs/:id）→ SIGINT 中断远端 apt
				job.finish(JobCancelled, "已取消")
				send(gin.H{"event": "done", "ok": false, "canceled": true})
			default:
				job.finish(JobFailed, errPackageUpdate)
				log.Printf("apt 更新（server #%d）失败: %v", id, runErr)
				send(gin.H{"event": "done", "ok": false, "error": errPackageUpdate})
			}

			sid := id
			_ = db.InsertAudit(d, uid, &sid, "packages.update", "apt-get update && upgrade -y", string(job.Snapshot().Status))
		}()

		// SSE 主循环：等待 job 终态；客户端断开则仅 detach（不取消 job ctx）。
		ticker := time.NewTicker(300 * time.Millisecond)
		defer ticker.Stop()

		// 心跳：Cloudflare 对源站有约 100 秒的空闲超时。apt 在等 dpkg 锁、
		// 解压大包时可能长时间一行输出都没有，没有心跳连接会被中间层切断，
		// 客户端表现为「升级流毫无征兆地结束」。注释帧以 ":" 开头，按 SSE
		// 规范会被客户端忽略（App 的解析器只认 "data:" 开头的行）。
		keepalive := time.NewTicker(15 * time.Second)
		defer keepalive.Stop()

		for {
			select {
			case <-c.Request.Context().Done():
				// 客户端断连：仅 detach，底层升级继续（job ctx 独立）
				detached.Store(true)
				return
			case <-keepalive.C:
				writeRaw(": keepalive\n\n")
			case <-ticker.C:
				if job.isTerminal() {
					return
				}
			}
		}
	}
}
