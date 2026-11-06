package api

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"golang.org/x/crypto/ssh"
)

// 交互式终端的边界值。
//
// 为什么并发要限额：SSH 交互会话与被管机 sshd 的 MaxSessions 抢配额，
// 手滑连开十个会把「日志/采集」这类后台连接一起挤掉，而它们失败时的
// 表现是「面板显示离线」，排查方向会被带偏。自用场景 3 个足够。
const (
	termPingInterval = 30 * time.Second
	termReadTimeout  = 90 * time.Second
	termWriteTimeout = 10 * time.Second
	termMaxPerServer = 3
	// 忘关的终端等于一把长期敞开的 root shell，必须有上限。
	termMaxLifetime = 4 * time.Hour
	termDefaultCols = 80
	termDefaultRows = 24
	termMinCols     = 20
	termMaxCols     = 500
	termMinRows     = 5
	termMaxRows     = 200
)

// 终端 WS 帧。
//
// 载荷一律 base64，不用裸字符串：PTY 的输出是**任意字节流**，读一次
// 可能正好切在一个 UTF-8 多字节字符中间（中文/emoji 尤其常见）。若按
// 字符串逐帧传，那一帧就不是合法 UTF-8，客户端解码时会把字符替换成
// U+FFFD——表现是中文乱码、进度条花屏，而且只在输出量大时才复现。
// 这类 bug 在本地测试几乎撞不到，一旦上线就是「终端没法用」。
//
// 连接建立后客户端主动发一帧 {"t":"r"} 对齐真实尺寸；服务端按该尺寸
// 起 PTY，避免首屏按 80x24 排版再被 resize 重排（重排会丢掉部分滚动内容）。
type termClientMsg struct {
	T string `json:"t"`           // i=输入 r=尺寸 p=心跳
	D string `json:"d,omitempty"` // base64 输入字节
	C int    `json:"c,omitempty"` // 列
	R int    `json:"r,omitempty"` // 行
}

type termServerMsg struct {
	T    string `json:"t"`           // o=输出 x=结束 e=错误
	D    string `json:"d,omitempty"` // base64 输出字节
	Code *int   `json:"code,omitempty"`
	M    string `json:"m,omitempty"`
}

// terminalUpgrader 与日志流同参数：单用户自用，前置有 Cloudflare Access。
var terminalUpgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

// termDial 是拨号接缝，默认走真实 SSH；测试里替换成管道上的假服务端，
// 好在不解网络的情况下验证「字节进 → 字节出」这条链路。
var termDial sshpool.Dialer = sshpool.DefaultDialer

// 单机并发终端计数。进程内即可——面板是单实例部署，重启后计数归零也合理。
var termSlots = struct {
	mu sync.Mutex
	m  map[int64]int
}{m: make(map[int64]int)}

func termAcquire(serverID int64) bool {
	termSlots.mu.Lock()
	defer termSlots.mu.Unlock()
	if termSlots.m[serverID] >= termMaxPerServer {
		return false
	}
	termSlots.m[serverID]++
	return true
}

func termRelease(serverID int64) {
	termSlots.mu.Lock()
	defer termSlots.mu.Unlock()
	if termSlots.m[serverID] <= 1 {
		delete(termSlots.m, serverID)
		return
	}
	termSlots.m[serverID]--
}

// authorizeTerminal 只认 Authorization 头。
//
// 不复用 authorizeWS：那套是为浏览器准备的一次性票据，票据里绑的是
// containerID。给终端再造一种票据等于多一条可被复用的凭据路径，而 App
// 的 WebSocket 客户端本来就能带自定义头，没有必要。
func authorizeTerminal(c *gin.Context, secret string) (int64, error) {
	h := c.GetHeader("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return 0, ErrUnauthorized("缺少访问令牌")
	}
	claims, err := auth.ParseAccessToken(secret, strings.TrimSpace(strings.TrimPrefix(h, "Bearer ")))
	if err != nil {
		return 0, ErrUnauthorized("访问令牌无效或已过期")
	}
	return claims.UserID, nil
}

// termSize 解析并夹紧终端尺寸。
//
// 夹紧不是防御性编程洁癖：客户端的行列来自布局计算，软键盘弹出/收起时
// 会瞬间产出 0 行或负数，直接透传给 RequestPty 会让远端 shell 的
// $LINES 变成 0，`less`/`vim` 会画出空屏。
func termSize(c *gin.Context) (cols, rows int) {
	cols = clampInt(intQuery(c, "cols", termDefaultCols), termMinCols, termMaxCols)
	rows = clampInt(intQuery(c, "rows", termDefaultRows), termMinRows, termMaxRows)
	return cols, rows
}

// intQuery 读一个整数查询参数；缺省或非法时回退到 def。
func intQuery(c *gin.Context, key string, def int) int {
	v, err := strconv.Atoi(strings.TrimSpace(c.Query(key)))
	if err != nil {
		return def
	}
	return v
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// serverTerminalHandler 把一条 SSH 交互会话桥接成 WebSocket。
// GET /api/servers/:id/terminal?cols=80&rows=24
//
// 与日志流的区别：日志是「服务端跑一条命令，单向吐」，本端点要双向、
// 要 PTY、要能 resize，所以不能复用 sshpool 里的长连接——连接池会被
// Reap 按空闲回收，而人挂着一个终端不动是很正常的，回收掉就是「用着
// 用着突然断」。这里为每次终端单开一条 SSH 连接，关页面即断。
func serverTerminalHandler(d *sql.DB, masterKey, secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		uid, authErr := authorizeTerminal(c, secret)
		if authErr != nil {
			Fail(c, authErr)
			return
		}
		cols, rows := termSize(c)

		if !termAcquire(id) {
			Fail(c, ErrConflict(fmt.Sprintf("这台机器已有 %d 个终端在开，先关掉一个再连", termMaxPerServer)))
			return
		}
		released := false
		release := func() {
			if !released {
				released = true
				termRelease(id)
			}
		}
		defer release()

		srv, err := db.GetServer(d, id)
		if errors.Is(err, db.ErrServerNotFound) {
			Fail(c, ErrNotFound("服务器不存在"))
			return
		}
		if err != nil {
			Fail(c, err)
			return
		}
		cred, err := db.GetDecryptedCredential(d, masterKey, id)
		if err != nil {
			Fail(c, err)
			return
		}

		dialCtx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
		defer cancel()
		cli, err := termDial(dialCtx, sshpool.Config{
			Host:       srv.Host,
			Port:       srv.Port,
			User:       srv.SSHUser,
			AuthMethod: cred.AuthMethod,
			Password:   cred.Password,
			PrivateKey: cred.PrivateKey,
			KeyPass:    cred.KeyPass,
		})
		if err != nil {
			Fail(c, ErrBadGateway("SSH 连接失败: "+err.Error()))
			return
		}
		defer func() { _ = cli.Close() }()

		sess, err := cli.NewSession()
		if err != nil {
			Fail(c, ErrBadGateway("创建 SSH 会话失败: "+err.Error()))
			return
		}
		defer func() { _ = sess.Close() }()

		modes := ssh.TerminalModes{
			ssh.ECHO:          1,
			ssh.TTY_OP_ISPEED: 14400,
			ssh.TTY_OP_OSPEED: 14400,
		}
		// RequestPty 的参数顺序是 (term, height, width)——行在前列在后，
		// 与 WindowChange 的 (h, w) 一致。写反的后果是竖屏 120 列宽 400 行高，
		// 首屏看起来像终端「只填了左上角一小块」。
		if err := sess.RequestPty("xterm-256color", rows, cols, modes); err != nil {
			Fail(c, ErrBadGateway("申请 PTY 失败: "+err.Error()))
			return
		}

		// 管道必须在 Shell/Start 之前取，之后再取会报「stdout already used」。
		// 只取 stdout：PTY 下 stderr 已并入同一通道，再取 stderr 拿到的是空管道。
		stdout, err := sess.StdoutPipe()
		if err != nil {
			Fail(c, ErrBadGateway("获取终端输出流失败: "+err.Error()))
			return
		}
		stdin, err := sess.StdinPipe()
		if err != nil {
			Fail(c, ErrBadGateway("获取终端输入流失败: "+err.Error()))
			return
		}

		// 远端 locale 常是 POSIX，那样中文会按字节透传，客户端解出来就是乱码。
		// sshd 默认拒绝 AcceptEnv，失败不致命：能设就设，设不了照常连接。
		_ = sess.Setenv("LANG", "C.UTF-8")
		_ = sess.Setenv("TERM", "xterm-256color")

		if err := sess.Shell(); err != nil {
			Fail(c, ErrBadGateway("启动交互 shell 失败: "+err.Error()))
			return
		}

		conn, err := terminalUpgrader.Upgrade(c.Writer, c.Request, nil)
		if err != nil {
			_ = sess.Signal(ssh.SIGTERM)
			return
		}
		defer func() { _ = conn.Close() }()

		started := time.Now()
		insertTerminalAudit(d, uid, id, "open", "ok")

		var (
			writeMu sync.Mutex
			done    = make(chan struct{})
			once    sync.Once
		)
		finish := func() { once.Do(func() { close(done) }) }

		write := func(m termServerMsg) error {
			writeMu.Lock()
			defer writeMu.Unlock()
			if err := conn.SetWriteDeadline(time.Now().Add(termWriteTimeout)); err != nil {
				return err
			}
			return conn.WriteJSON(m)
		}

		// 远端 → 客户端
		go func() {
			buf := make([]byte, 32*1024)
			for {
				n, rerr := stdout.Read(buf)
				if n > 0 {
					enc := base64.StdEncoding.EncodeToString(buf[:n])
					if werr := write(termServerMsg{T: "o", D: enc}); werr != nil {
						finish()
						return
					}
				}
				if rerr != nil {
					finish()
					return
				}
			}
		}()

		// 心跳：手机切网/锁屏留下的半开 TCP 不会被 Write 立刻发现，
		// 靠 ping + pong 超时才能把 SSH 会话收干净（与日志流同一套节奏）。
		go func() {
			t := time.NewTicker(termPingInterval)
			defer t.Stop()
			for {
				select {
				case <-t.C:
					writeMu.Lock()
					_ = conn.SetWriteDeadline(time.Now().Add(termWriteTimeout))
					_ = conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(termWriteTimeout))
					writeMu.Unlock()
				case <-done:
					return
				}
			}
		}()

		// 等 shell 自己退出（用户敲 exit / 进程被杀）。
		waitCh := make(chan error, 1)
		go func() { waitCh <- sess.Wait() }()

		// 客户端 → 远端
		go func() {
			defer finish()
			_ = conn.SetReadDeadline(time.Now().Add(termReadTimeout))
			conn.SetPongHandler(func(string) error {
				return conn.SetReadDeadline(time.Now().Add(termReadTimeout))
			})
			for {
				var m termClientMsg
				if rerr := conn.ReadJSON(&m); rerr != nil {
					return
				}
				switch m.T {
				case "i":
					if m.D == "" {
						continue
					}
					raw, derr := base64.StdEncoding.DecodeString(m.D)
					if derr != nil {
						continue
					}
					if _, werr := stdin.Write(raw); werr != nil {
						return
					}
				case "r":
					c2 := clampInt(m.C, termMinCols, termMaxCols)
					r2 := clampInt(m.R, termMinRows, termMaxRows)
					_ = sess.WindowChange(r2, c2)
				case "p":
					// 应用层心跳，收到即续期读超时。
					_ = conn.SetReadDeadline(time.Now().Add(termReadTimeout))
				}
			}
		}()

		lifetime := time.NewTimer(termMaxLifetime)
		defer lifetime.Stop()

		select {
		case werr := <-waitCh:
			code := termExitCode(werr)
			_ = write(termServerMsg{T: "x", Code: &code})
		case <-done:
			// 客户端主动断开或网络断了：让远端 shell 一起结束，别留孤儿进程。
			_ = sess.Signal(ssh.SIGTERM)
		case <-lifetime.C:
			_ = write(termServerMsg{T: "e", M: "会话已达 4 小时上限，已自动断开"})
			_ = sess.Signal(ssh.SIGTERM)
		}

		finish()
		insertTerminalAudit(d, uid, id, "close", "ok "+time.Since(started).Round(time.Second).String())
	}
}

// termExitCode 把 Wait 的返回换成 shell 退出码；-1 表示非正常退出（被信号杀/连接断）。
func termExitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *ssh.ExitError
	if errors.As(err, &ee) {
		return ee.ExitStatus()
	}
	return -1
}

// insertTerminalAudit 记录终端的开启与关闭。
//
// 只记元数据，不记按键流：终端里敲的东西可能包含口令、密钥、明文备份，
// 全量留存等于在审计表里堆一份敏感数据。要追责时，「谁在什么时候开了
// 哪台机器的终端、开了多久」已经足够定位，具体命令由被管机自己的
// auth.log / history 负责。
func insertTerminalAudit(d *sql.DB, uid, serverID int64, phase, result string) {
	if uid == 0 {
		return
	}
	sid := serverID
	_ = db.InsertAudit(d, uid, &sid, "server.terminal", phase, result)
}
