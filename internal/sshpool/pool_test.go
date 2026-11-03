package sshpool

import (
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestAuthMethodsPassword(t *testing.T) {
	cfg := Config{AuthMethod: "password", Password: "p"}
	methods, err := cfg.authMethods()
	if err != nil {
		t.Fatalf("authMethods: %v", err)
	}
	if len(methods) != 1 {
		t.Errorf("len=%d, want 1", len(methods))
	}
}

func TestAuthMethodsPasswordEmpty(t *testing.T) {
	cfg := Config{AuthMethod: "password"}
	if _, err := cfg.authMethods(); err == nil {
		t.Error("密码为空应报错")
	}
}

func TestAuthMethodsKeyEmpty(t *testing.T) {
	cfg := Config{AuthMethod: "key"}
	if _, err := cfg.authMethods(); err == nil {
		t.Error("私钥为空应报错")
	}
}

func TestAuthMethodsUnknown(t *testing.T) {
	cfg := Config{AuthMethod: "weird"}
	if _, err := cfg.authMethods(); err == nil {
		t.Error("未知认证方式应报错")
	}
}

func TestConfigDefaults(t *testing.T) {
	cfg := Config{Host: "1.2.3.4"}
	if cfg.port() != 22 {
		t.Errorf("port=%d, want 22", cfg.port())
	}
	if cfg.user() != "root" {
		t.Errorf("user=%q, want root", cfg.user())
	}
	if cfg.addr() != "1.2.3.4:22" {
		t.Errorf("addr=%q", cfg.addr())
	}
}

func TestPoolEmpty(t *testing.T) {
	p := NewPool(time.Minute)
	if p.Len() != 0 {
		t.Errorf("Len=%d, want 0", p.Len())
	}
	if n := p.Reap(); n != 0 {
		t.Errorf("Reap=%d, want 0", n)
	}
	p.Close(1)
	p.CloseAll()
	if p.Len() != 0 {
		t.Errorf("Len=%d, want 0", p.Len())
	}
}

func TestGetDialError(t *testing.T) {
	p := NewPool(time.Minute)
	p.SetDialer(func(ctx context.Context, cfg Config) (*ssh.Client, error) {
		return nil, errors.New("dial boom")
	})

	if _, err := p.Get(context.Background(), 1, Config{Host: "x"}); err == nil {
		t.Fatal("建连失败应返回错误")
	}
	if p.Len() != 0 {
		t.Errorf("建连失败不应缓存连接，Len=%d", p.Len())
	}
}

// 下面几条用零值 *ssh.Client 当占位：aliveFn 被替换为恒真，测试不调用其方法，
// 只比较指针与拨号次数，够用来验证池的调度逻辑。
func newTestPool(dials *int32, delay time.Duration) *Pool {
	p := NewPool(time.Minute)
	p.SetDialer(func(ctx context.Context, cfg Config) (*ssh.Client, error) {
		atomic.AddInt32(dials, 1)
		if delay > 0 {
			time.Sleep(delay)
		}
		return &ssh.Client{}, nil
	})
	p.aliveFn = func(*ssh.Client) bool { return true }
	return p
}

func TestGetReusesCachedConnection(t *testing.T) {
	var dials int32
	p := newTestPool(&dials, 0)

	first, err := p.Get(context.Background(), 7, Config{Host: "x"})
	if err != nil {
		t.Fatalf("首次 Get: %v", err)
	}
	second, err := p.Get(context.Background(), 7, Config{Host: "x"})
	if err != nil {
		t.Fatalf("二次 Get: %v", err)
	}
	if first != second {
		t.Error("同一 serverID 应复用同一条连接")
	}
	if got := atomic.LoadInt32(&dials); got != 1 {
		t.Errorf("拨号 %d 次，期望 1 次", got)
	}
}

func TestGetConcurrentSingleFlight(t *testing.T) {
	var dials int32
	// 拨号故意慢 50ms，让其它 goroutine 都落进「等待别人建连」的分支。
	p := newTestPool(&dials, 50*time.Millisecond)

	const n = 8
	var wg sync.WaitGroup
	clients := make([]*ssh.Client, n)
	errs := make([]error, n)
	for i := 0; i < n; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			clients[i], errs[i] = p.Get(context.Background(), 9, Config{Host: "x"})
		}()
	}
	wg.Wait()

	for i := 0; i < n; i++ {
		if errs[i] != nil {
			t.Fatalf("第 %d 个 Get 失败: %v", i, errs[i])
		}
		if clients[i] != clients[0] {
			t.Errorf("第 %d 个 Get 拿到了不同连接", i)
		}
	}
	if got := atomic.LoadInt32(&dials); got != 1 {
		t.Errorf("并发 Get 拨号 %d 次，期望 1 次", got)
	}
}

// fakeConn 只实现 ssh.Conn 的 Close 等空方法，供「探活失败要关闭连接」的用例
// 安全地走到 Close 而不 panic（零值 *ssh.Client 的 Conn 是 nil）。
type fakeConn struct{ closed int32 }

func (c *fakeConn) User() string          { return "u" }
func (c *fakeConn) SessionID() []byte     { return nil }
func (c *fakeConn) ClientVersion() []byte { return nil }
func (c *fakeConn) ServerVersion() []byte { return nil }
func (c *fakeConn) SendRequest(string, bool, []byte) (bool, []byte, error) {
	return true, nil, nil
}
func (c *fakeConn) OpenChannel(string, []byte) (ssh.Channel, <-chan *ssh.Request, error) {
	return nil, nil, nil
}
func (c *fakeConn) Close() error         { atomic.AddInt32(&c.closed, 1); return nil }
func (c *fakeConn) LocalAddr() net.Addr  { return nil }
func (c *fakeConn) RemoteAddr() net.Addr { return nil }
func (c *fakeConn) Wait() error          { return nil }

// 空闲但健康：不能被回收。这正是「长任务不被腰斩」的保证——
// apt 升级跑过 idleTTL，连接仍然是活的，Reap 必须放过它。
func TestReapKeepsIdleButHealthyConnection(t *testing.T) {
	var dials, probes int32
	p := newTestPool(&dials, 0)
	base := time.Now()
	p.now = func() time.Time { return base }
	p.aliveFn = func(*ssh.Client) bool { atomic.AddInt32(&probes, 1); return true }

	if _, err := p.Get(context.Background(), 3, Config{Host: "x"}); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if n := p.Reap(); n != 0 {
		t.Errorf("未超时不应回收，实际 %d", n)
	}
	if got := atomic.LoadInt32(&probes); got != 0 {
		t.Errorf("未超时不应探活，实际探活 %d 次", got)
	}

	p.now = func() time.Time { return base.Add(2 * time.Minute) }
	if n := p.Reap(); n != 0 {
		t.Errorf("健康连接不应被回收，实际 %d", n)
	}
	if p.Len() != 1 {
		t.Errorf("健康连接应保留，Len=%d", p.Len())
	}
	if got := atomic.LoadInt32(&probes); got != 1 {
		t.Errorf("超时后应探活 1 次，实际 %d", got)
	}
	if got := atomic.LoadInt32(&dials); got != 1 {
		t.Errorf("回收不应触发重新拨号，拨号 %d 次", got)
	}
}

// 空闲且已死：必须回收，否则长期不访问的机器会一直占着半死 socket 与读写 goroutine。
func TestReapDropsDeadConnection(t *testing.T) {
	var dials int32
	p := newTestPool(&dials, 0)
	base := time.Now()
	p.now = func() time.Time { return base }

	conn := &fakeConn{}
	p.SetDialer(func(context.Context, Config) (*ssh.Client, error) {
		atomic.AddInt32(&dials, 1)
		return &ssh.Client{Conn: conn}, nil
	})
	p.aliveFn = func(*ssh.Client) bool { return true }

	if _, err := p.Get(context.Background(), 4, Config{Host: "x"}); err != nil {
		t.Fatalf("Get: %v", err)
	}

	// 连接随后半死（NAT 静默丢弃 → TCP 半开），探活恒失败。
	p.aliveFn = func(*ssh.Client) bool { return false }
	p.now = func() time.Time { return base.Add(2 * time.Minute) }
	if n := p.Reap(); n != 1 {
		t.Errorf("死连接应回收 1 条，实际 %d", n)
	}
	if p.Len() != 0 {
		t.Errorf("死连接应已从池中移除，Len=%d", p.Len())
	}
	if got := atomic.LoadInt32(&conn.closed); got != 1 {
		t.Errorf("死连接应被关闭 1 次，实际 %d", got)
	}
}

// 死亡连接被回收后，下一次 Get 应重建——不能留下「移除但未关闭」或反向的残留。
func TestGetRebuildsAfterDeadConnectionReaped(t *testing.T) {
	var dials, probes int32
	p := newTestPool(&dials, 0)
	p.SetDialer(func(context.Context, Config) (*ssh.Client, error) {
		atomic.AddInt32(&dials, 1)
		return &ssh.Client{Conn: &fakeConn{}}, nil
	})
	base := time.Now()
	p.now = func() time.Time { return base }
	p.aliveFn = func(*ssh.Client) bool { return atomic.LoadInt32(&probes) == 0 }

	if _, err := p.Get(context.Background(), 5, Config{Host: "x"}); err != nil {
		t.Fatalf("首次 Get: %v", err)
	}
	atomic.StoreInt32(&probes, 1) // 之后探活恒失败
	p.now = func() time.Time { return base.Add(2 * time.Minute) }
	if n := p.Reap(); n != 1 {
		t.Fatalf("应回收死连接，实际 %d", n)
	}

	p.now = func() time.Time { return base.Add(3 * time.Minute) }
	if _, err := p.Get(context.Background(), 5, Config{Host: "x"}); err != nil {
		t.Fatalf("回收后 Get: %v", err)
	}
	if got := atomic.LoadInt32(&dials); got != 2 {
		t.Errorf("回收后应重新拨号，累计拨号 %d 次", got)
	}
}
