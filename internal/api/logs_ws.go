package api

import (
	"database/sql"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/yy1319hua/fleetboard/internal/docker"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"golang.org/x/crypto/ssh"
)

// WS 日志流的心跳参数：30s 主动 ping，90s 收不到 pong 判定对端已死。
// 90s 取 ping 间隔的三倍，允许丢两次不误杀。
const (
	wsPingInterval = 30 * time.Second
	wsReadTimeout  = 90 * time.Second
)

var logsUpgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	// 单用户自用，前置有 Cloudflare Access；此处不做跨域额外限制。
	CheckOrigin: func(r *http.Request) bool { return true },
}

// containerLogsHandler 升级为 WebSocket，持续推送 `docker logs -f` 输出。
// GET /api/servers/:id/containers/:cid/logs?tail=200&ticket=<一次性票据>
//
// 鉴权：优先 Authorization 头（能带头部的客户端），否则用 ?ticket=（浏览器）；
// 该端点不在 JWTAuth 组内，鉴权在本函数内完成。
func containerLogsHandler(d *sql.DB, masterKey, secret string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		cid := c.Param("cid")

		uid, authErr := authorizeWS(c, secret, id, cid)
		if authErr != nil {
			Fail(c, authErr)
			return
		}

		cmdline, err := docker.LogsCommand(cid, c.DefaultQuery("tail", "200"))
		if err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}

		cli, err := openSSH(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}

		sess, err := cli.NewSession()
		if err != nil {
			Fail(c, ErrBadGateway("创建 SSH 会话失败: "+err.Error()))
			return
		}
		defer func() { _ = sess.Close() }()

		stdout, err := sess.StdoutPipe()
		if err != nil {
			Fail(c, ErrBadGateway("获取日志流失败: "+err.Error()))
			return
		}
		stderr, err := sess.StderrPipe()
		if err != nil {
			Fail(c, ErrBadGateway("获取日志流失败: "+err.Error()))
			return
		}

		if err := sess.Start(cmdline); err != nil {
			Fail(c, ErrBadGateway("启动日志命令失败: "+err.Error()))
			return
		}

		conn, err := logsUpgrader.Upgrade(c.Writer, c.Request, nil)
		if err != nil {
			_ = sess.Signal(ssh.SIGTERM)
			return
		}
		defer func() { _ = conn.Close() }()

		insertLogsAudit(d, uid, id, cid)

		var writeMu sync.Mutex
		write := func(p []byte) error {
			writeMu.Lock()
			defer writeMu.Unlock()
			return conn.WriteMessage(websocket.TextMessage, p)
		}

		// 心跳：手机切网、进后台、进程被杀都会留下半开的 TCP。服务端原本只在
		// 下一次写日志时才发现对端已走，期间一直占着一条 SSH exec 不释放。
		// 改为服务端主动 ping，客户端（浏览器与 dart:io WebSocket）自动回 pong；
		// 超过 wsReadTimeout 没有 pong 就让 ReadMessage 报错，从而关连接、收 SSH。
		_ = conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
		conn.SetPongHandler(func(string) error {
			return conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
		})

		// 客户端断开检测：读循环出错即取消
		done := make(chan struct{})
		go func() {
			defer close(done)
			for {
				if _, _, err := conn.ReadMessage(); err != nil {
					return
				}
			}
		}()

		go func() {
			t := time.NewTicker(wsPingInterval)
			defer t.Stop()
			for {
				select {
				case <-done:
					return
				case <-t.C:
					// gorilla 禁止 WriteControl 与 WriteMessage 并发（会 panic
					// "concurrent write to websocket connection"），必须共用 writeMu。
					writeMu.Lock()
					err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
					writeMu.Unlock()
					if err != nil {
						return
					}
				}
			}
		}()

		lines := make(chan []byte, 64)
		var wg sync.WaitGroup

		pump := func(r io.Reader) {
			defer wg.Done()
			buf := make([]byte, 4096)
			for {
				n, err := r.Read(buf)
				if n > 0 {
					b := make([]byte, n)
					copy(b, buf[:n])
					select {
					case lines <- b:
					case <-done:
						return
					}
				}
				if err != nil {
					return
				}
			}
		}

		wg.Add(2)
		go pump(stdout)
		go pump(stderr)
		go func() {
			wg.Wait()
			close(lines)
		}()

		for {
			select {
			case b, ok := <-lines:
				if !ok {
					return
				}
				if err := write(b); err != nil {
					return
				}
			case <-done:
				_ = sess.Signal(ssh.SIGTERM)
				return
			}
		}
	}
}
