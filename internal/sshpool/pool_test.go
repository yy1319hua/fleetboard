package sshpool

import (
	"context"
	"errors"
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

func TestReapMarksIdleWithoutDropping(t *testing.T) {
	var dials int32
	p := newTestPool(&dials, 0)
	base := time.Now()
	p.now = func() time.Time { return base }

	if _, err := p.Get(context.Background(), 3, Config{Host: "x"}); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if n := p.Reap(); n != 0 {
		t.Errorf("未超时应标记 0 条，实际 %d", n)
	}

	// 超过 idleTTL：标记 stale，但**不从池里删除、不关闭**——连接可能正被
	// apt 升级或 docker logs -f 使用，关掉会把任务腰斩。
	p.now = func() time.Time { return base.Add(2 * time.Minute) }
	if n := p.Reap(); n != 1 {
		t.Errorf("超时应标记 1 条，实际 %d", n)
	}
	if p.Len() != 1 {
		t.Errorf("Reap 不应删除条目，Len=%d", p.Len())
	}
	if n := p.Reap(); n != 0 {
		t.Errorf("已标记的条目不应重复计数，实际 %d", n)
	}
}
