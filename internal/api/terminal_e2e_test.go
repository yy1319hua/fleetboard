package api

// 终端桥接的端到端测试：不碰外网、不碰真机，用 net.Pipe 起一个假 SSH 服务端，
// 把「WS 帧 → SSH stdin → 假 shell → SSH stdout → WS 帧」整条链路走一遍。
//
// 为什么值得写：这段代码里最容易出错的三处——PTY 尺寸方向、字节的 base64
// 往返、window-change 是否真的下发——都属于「编译能过、真机才发现终端不能用」
// 的类型。假服务端能把它们的失败显性化。

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"golang.org/x/crypto/ssh"
)

// fakeShell 记录假服务端收到的交互请求。
type fakeShell struct {
	mu    sync.Mutex
	cols  int
	rows  int
	pty   bool
	shell bool
}

func (f *fakeShell) record(cols, rows int) {
	f.mu.Lock()
	f.cols, f.rows = cols, rows
	f.mu.Unlock()
}

func (f *fakeShell) size() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.cols, f.rows
}

func (f *fakeShell) flags() (bool, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pty, f.shell
}

// startFakeSSH 起一个只实现 session/pty-req/shell/window-change 的假 SSH 服务端。
// onInput 收到一段用户输入，返回要「打印」回终端的若干块——分块是为了能构造
// 「多字节字符跨帧」这种真实但难复现的情形。
func startFakeSSH(t *testing.T, onInput func(in string) []string) (*ssh.Client, *fakeShell) {
	t.Helper()

	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("生成主机密钥: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatalf("主机密钥转 signer: %v", err)
	}
	srvCfg := &ssh.ServerConfig{NoClientAuth: true}
	srvCfg.AddHostKey(signer)

	// 用真 TCP 而不是 net.Pipe：SSH 双方会同时写版本串，无缓冲管道上会互等死锁。
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听假 sshd: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	state := &fakeShell{}

	go func() {
		raw, err := ln.Accept()
		if err != nil {
			return
		}
		defer raw.Close()
		_, chans, reqs, err := ssh.NewServerConn(raw, srvCfg)
		if err != nil {
			return
		}
		go ssh.DiscardRequests(reqs)
		for nc := range chans {
			if nc.ChannelType() != "session" {
				_ = nc.Reject(ssh.UnknownChannelType, "no")
				continue
			}
			ch, chReqs, err := nc.Accept()
			if err != nil {
				continue
			}
			go func() {
				for req := range chReqs {
					switch req.Type {
					case "pty-req":
						term, cols, rows := parsePtyReq(req.Payload)
						_ = term
						state.record(int(cols), int(rows))
						state.mu.Lock()
						state.pty = true
						state.mu.Unlock()
						_ = req.Reply(true, nil)
					case "shell":
						state.mu.Lock()
						state.shell = true
						state.mu.Unlock()
						_ = req.Reply(true, nil)
						go func() {
							buf := make([]byte, 1024)
							for {
								n, err := ch.Read(buf)
								if n > 0 {
									for _, chunk := range onInput(string(buf[:n])) {
										if chunk == "" {
											continue
										}
										_, _ = ch.Write([]byte(chunk))
										// 留一点间隔，确保服务端两次 Read 之间
										// 客户端确实收到了前一帧。
										time.Sleep(10 * time.Millisecond)
									}
								}
								if err != nil {
									return
								}
							}
						}()
					case "window-change":
						var wc struct{ Cols, Rows, Width, Height uint32 }
						_ = ssh.Unmarshal(req.Payload, &wc)
						state.record(int(wc.Cols), int(wc.Rows))
						_ = req.Reply(true, nil)
					default:
						_ = req.Reply(false, nil)
					}
				}
			}()
		}
	}()

	cli, err := ssh.Dial("tcp", ln.Addr().String(), &ssh.ClientConfig{
		User:            "tester",
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         5 * time.Second,
	})
	if err != nil {
		t.Fatalf("建立假 SSH 连接: %v", err)
	}
	t.Cleanup(func() { _ = cli.Close() })
	return cli, state
}

// parsePtyReq 按 RFC 4254 §6.2 解 pty-req：string term, uint32 cols, uint32 rows, ...
func parsePtyReq(payload []byte) (term string, cols, rows uint32) {
	if len(payload) < 4 {
		return "", 0, 0
	}
	n := int(payload[0])<<24 | int(payload[1])<<16 | int(payload[2])<<8 | int(payload[3])
	if len(payload) < 4+n+8 {
		return "", 0, 0
	}
	term = string(payload[4 : 4+n])
	p := payload[4+n:]
	cols = uint32(p[0])<<24 | uint32(p[1])<<16 | uint32(p[2])<<8 | uint32(p[3])
	rows = uint32(p[4])<<24 | uint32(p[5])<<16 | uint32(p[6])<<8 | uint32(p[7])
	return term, cols, rows
}

// newTermTestRouter 与 newAuthTestServer 等价，但数据库目录由本函数自己管。
//
// 为什么不复用 newAuthTestServer：它把 DB 放在 t.TempDir() 里，而 sqlite 关闭时
// 的 WAL 收尾与 TempDir 的删除会撞车，偶发 "directory not empty" 让测试假红。
// 这里自己建目录并在删除失败时重试，把偶发性挡在测试基建里，不污染断言。
func newTermTestRouter(t *testing.T) (*gin.Engine, *sql.DB) {
	t.Helper()
	dir, err := os.MkdirTemp("", "fleetboard-term")
	if err != nil {
		t.Fatalf("建临时目录: %v", err)
	}
	d, err := db.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	if _, err := db.EnsureAdmin(d, "admin", "pass123"); err != nil {
		t.Fatalf("EnsureAdmin: %v", err)
	}
	t.Cleanup(func() {
		_ = d.Close()
		for i := 0; i < 5; i++ {
			if err := os.RemoveAll(dir); err == nil {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
	})
	gin.SetMode(gin.TestMode)
	return NewRouter(RouterOptions{
		DB:        d,
		JWTSecret: "test-secret",
		MasterKey: "test-master",
		Pool:      sshpool.NewPool(time.Minute),
	}), d
}

// seedServer 建一条指向假服务端的服务器记录，返回其 id。
func seedServer(t *testing.T, r http.Handler, token string) int64 {
	t.Helper()
	w := authReq(r, http.MethodPost, "/api/servers", token, map[string]any{
		"name": "fake", "host": "127.0.0.1", "port": 22,
		"auth_method": "password", "password": "pw",
	})
	if w.Code != http.StatusCreated {
		t.Fatalf("创建服务器失败 status=%d body=%s", w.Code, w.Body)
	}
	return 1
}

func dialTerminalWS(t *testing.T, srv *httptest.Server, serverID int64, token string, cols, rows int) *websocket.Conn {
	t.Helper()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") +
		fmt.Sprintf("/api/servers/%d/terminal?cols=%d&rows=%d", serverID, cols, rows)
	h := http.Header{}
	h.Set("Authorization", "Bearer "+token)
	conn, resp, err := websocket.DefaultDialer.Dial(url, h)
	if err != nil {
		code := 0
		if resp != nil {
			code = resp.StatusCode
		}
		t.Fatalf("WS 握手失败: %v (http %d)", err, code)
	}
	return conn
}

func readOutputFrame(t *testing.T, conn *websocket.Conn) []byte {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("读帧失败: %v", err)
		}
		var m termServerMsg
		if err := json.Unmarshal(raw, &m); err != nil {
			t.Fatalf("帧不是 JSON: %s", raw)
		}
		if m.T != "o" {
			continue
		}
		b, err := base64.StdEncoding.DecodeString(m.D)
		if err != nil {
			t.Fatalf("输出帧 base64 非法: %v", err)
		}
		return b
	}
}

func sendInput(t *testing.T, conn *websocket.Conn, s string) {
	t.Helper()
	b, _ := json.Marshal(termClientMsg{T: "i", D: base64.StdEncoding.EncodeToString([]byte(s))})
	if err := conn.WriteMessage(websocket.TextMessage, b); err != nil {
		t.Fatalf("写输入帧失败: %v", err)
	}
}

func TestTerminalBridgeEchoAndResize(t *testing.T) {
	cli, fake := startFakeSSH(t, func(in string) []string { return []string{"got:" + in} })
	termDial = func(context.Context, sshpool.Config) (*ssh.Client, error) { return cli, nil }
	t.Cleanup(func() { termDial = sshpool.DefaultDialer })

	r, _ := newTermTestRouter(t)
	tokens := loginTokens(t, r)
	id := seedServer(t, r, tokens.AccessToken)

	srv := httptest.NewServer(r)
	defer srv.Close()

	conn := dialTerminalWS(t, srv, id, tokens.AccessToken, 100, 30)
	defer conn.Close()

	// 1) 尺寸方向：pty-req 里 cols=100 / rows=30。写反的话真机上表现为
	//    「终端只占左上角一小块」，这里能立刻抓到。
	if c, rr := fake.size(); c != 100 || rr != 30 {
		t.Fatalf("PTY 尺寸应为 100 列 30 行，实际 %d 列 %d 行", c, rr)
	}
	if pty, shell := fake.flags(); !pty || !shell {
		t.Fatalf("应申请 PTY 并启动 shell（pty=%v shell=%v）", pty, shell)
	}

	// 2) 输入经 base64 到达远端，输出原样回来。
	sendInput(t, conn, "ls\r")
	if got := readOutputFrame(t, conn); string(got) != "got:ls\r" {
		t.Fatalf("回显不符：%q", got)
	}

	// 3) resize 送达远端。
	b, _ := json.Marshal(termClientMsg{T: "r", C: 44, R: 18})
	if err := conn.WriteMessage(websocket.TextMessage, b); err != nil {
		t.Fatalf("写 resize 帧失败: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if c, rr := fake.size(); c == 44 && rr == 18 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	c, rr := fake.size()
	t.Fatalf("resize 未送达，仍为 %d 列 %d 行", c, rr)
}

// 多字节字符跨帧：服务端把「中」拆成 1 字节 + 2 字节两次写，
// 客户端收到两帧，拼起来必须还原成完整汉字而不是两个 U+FFFD。
func TestTerminalBridgeMultibyteSplit(t *testing.T) {
	raw := []byte("中") // e4 b8 ad
	cli, _ := startFakeSSH(t, func(string) []string {
		return []string{string(raw[:1]), string(raw[1:])}
	})
	termDial = func(context.Context, sshpool.Config) (*ssh.Client, error) { return cli, nil }
	t.Cleanup(func() { termDial = sshpool.DefaultDialer })

	r, _ := newTermTestRouter(t)
	tokens := loginTokens(t, r)
	id := seedServer(t, r, tokens.AccessToken)
	srv := httptest.NewServer(r)
	defer srv.Close()

	conn := dialTerminalWS(t, srv, id, tokens.AccessToken, 80, 24)
	defer conn.Close()

	sendInput(t, conn, "x")
	var got []byte
	deadline := time.Now().Add(5 * time.Second)
	for len(got) < len(raw) && time.Now().Before(deadline) {
		got = append(got, readOutputFrame(t, conn)...)
	}
	if string(got) != "中" {
		t.Fatalf("多字节字符应完整到达，实际 %q", got)
	}
}
