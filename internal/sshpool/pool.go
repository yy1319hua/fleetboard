// Package sshpool 负责 SSH 连接池的建立、复用与回收。
package sshpool

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// Config 描述被管机的 SSH 连接参数（凭据为已解密的明文，仅内存中短暂存在）。
type Config struct {
	Host       string
	Port       int
	User       string
	AuthMethod string // password | key
	Password   string
	PrivateKey string
	KeyPass    string
}

func (c Config) port() int {
	if c.Port == 0 {
		return 22
	}
	return c.Port
}

func (c Config) user() string {
	if c.User == "" {
		return "root"
	}
	return c.User
}

func (c Config) addr() string {
	return net.JoinHostPort(c.Host, fmt.Sprintf("%d", c.port()))
}

// authMethods 构造 ssh.AuthMethod 列表。
func (c Config) authMethods() ([]ssh.AuthMethod, error) {
	switch c.AuthMethod {
	case "password":
		if c.Password == "" {
			return nil, errors.New("认证方式为 password 但密码为空")
		}
		return []ssh.AuthMethod{ssh.Password(c.Password)}, nil
	case "", "key":
		if c.PrivateKey == "" {
			return nil, errors.New("认证方式为 key 但私钥为空")
		}
		var (
			signer ssh.Signer
			err    error
		)
		if c.KeyPass != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(c.PrivateKey), []byte(c.KeyPass))
		} else {
			signer, err = ssh.ParsePrivateKey([]byte(c.PrivateKey))
		}
		if err != nil {
			return nil, fmt.Errorf("解析私钥失败: %w", err)
		}
		return []ssh.AuthMethod{ssh.PublicKeys(signer)}, nil
	default:
		return nil, fmt.Errorf("未知认证方式: %q", c.AuthMethod)
	}
}

// Dialer 抽象底层建连，便于测试注入。
type Dialer func(ctx context.Context, cfg Config) (*ssh.Client, error)

// DefaultDialer 使用标准 SSH 协议建连。
func DefaultDialer(ctx context.Context, cfg Config) (*ssh.Client, error) {
	auths, err := cfg.authMethods()
	if err != nil {
		return nil, err
	}

	cc := &ssh.ClientConfig{
		User: cfg.user(),
		Auth: auths,
		// 首次信任（TOFU）；后续可切换为 known_hosts 校验。
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         10 * time.Second,
	}

	d := &net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", cfg.addr())
	if err != nil {
		return nil, err
	}
	sc, chans, reqs, err := ssh.NewClientConn(conn, cfg.addr(), cc)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	return ssh.NewClient(sc, chans, reqs), nil
}

type entry struct {
	client   *ssh.Client
	lastUsed time.Time

	// stale 表示空闲已超时，等下一次 Get 时关闭旧连接并重建。
	// Reap 只打标记、不关闭——池里没有「会话是否在途」的信息，凭 lastUsed
	// 直接关会把跑得久的任务（apt 全量升级、docker logs -f、大文件传输）腰斩。
	stale bool
}

// dialCall 是一次进行中的建连，供并发 Get 的其它 goroutine 等待复用。
type dialCall struct {
	done chan struct{}
	err  error
}

// Pool 按 serverID 复用 SSH 长连接，并惰性/周期标记空闲连接。
type Pool struct {
	mu      sync.Mutex
	entries map[int64]*entry
	dialing map[int64]*dialCall
	idleTTL time.Duration
	dial    Dialer
	aliveFn func(*ssh.Client) bool
	now     func() time.Time
}

// NewPool 创建连接池；idleTTL 为空闲连接保留时长。
func NewPool(idleTTL time.Duration) *Pool {
	p := &Pool{
		entries: make(map[int64]*entry),
		dialing: make(map[int64]*dialCall),
		idleTTL: idleTTL,
		dial:    DefaultDialer,
		now:     time.Now,
	}
	p.aliveFn = p.probeAlive
	return p
}

// SetDialer 替换底层建连函数（测试用）。
func (p *Pool) SetDialer(d Dialer) { p.dial = d }

// Get 返回指定服务器可用的连接；已有连接失活则重建。
//
// 两条硬约束：
//  1. 持锁期间绝不建连、绝不做存活探测——一次最长 10s 的建连或 5s 的
//     keepalive 会让其它所有机器的请求排队等同一把锁，表现为「一台机器
//     不健康、整个面板卡住、所有机器一起掉线」。
//  2. 同一 serverID 的并发 Get 只建一条连接（singleflight），其余等待复用。
func (p *Pool) Get(ctx context.Context, serverID int64, cfg Config) (*ssh.Client, error) {
	if cli, ok := p.reusable(serverID); ok {
		return cli, nil
	}
	return p.dialOnce(ctx, serverID, cfg)
}

// reusable 取出池中可用连接。锁内只做取指针与刷新 lastUsed，探测在锁外。
// 失活或已标记 stale 的条目会被移除，并在锁外关闭。
func (p *Pool) reusable(serverID int64) (*ssh.Client, bool) {
	p.mu.Lock()
	e, ok := p.entries[serverID]
	if !ok {
		p.mu.Unlock()
		return nil, false
	}
	if e.stale {
		delete(p.entries, serverID)
		p.mu.Unlock()
		_ = e.client.Close()
		return nil, false
	}
	cli := e.client
	e.lastUsed = p.now()
	p.mu.Unlock()

	if p.aliveFn(cli) {
		return cli, true
	}
	p.invalidate(serverID, cli)
	return nil, false
}

// invalidate 移除并关闭一条已判定失活的连接；只在条目仍是这条连接时动手。
func (p *Pool) invalidate(serverID int64, cli *ssh.Client) {
	p.mu.Lock()
	if e, ok := p.entries[serverID]; ok && e.client == cli {
		delete(p.entries, serverID)
	}
	p.mu.Unlock()
	_ = cli.Close()
}

// dialOnce 建连并把结果放进池；同一 serverID 并发时只有一个真正的拨号者。
func (p *Pool) dialOnce(ctx context.Context, serverID int64, cfg Config) (*ssh.Client, error) {
	p.mu.Lock()
	if call, ok := p.dialing[serverID]; ok {
		p.mu.Unlock()
		select {
		case <-call.done:
			if call.err != nil {
				return nil, call.err
			}
			if cli, ok := p.reusable(serverID); ok {
				return cli, nil
			}
			return nil, errors.New("sshpool: 连接建立后不可用")
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	call := &dialCall{done: make(chan struct{})}
	p.dialing[serverID] = call
	p.mu.Unlock()

	cli, err := p.dial(ctx, cfg) // 锁外拨号，慢的只是这一台

	p.mu.Lock()
	delete(p.dialing, serverID)
	if err == nil {
		p.entries[serverID] = &entry{client: cli, lastUsed: p.now()}
	}
	call.err = err
	p.mu.Unlock()
	close(call.done)

	if err != nil {
		return nil, err
	}
	return cli, nil
}

// Probe 用给定配置拨一次 SSH，成功即刻关闭并返回耗时；**不入池、不缓存**。
//
// 纳管预检在没有 serverID 时调用：既没有可复用的连接，也不该为一次性的
// 试探在池子里占一个槽位（否则试探失败还会留下半死条目）。
func (p *Pool) Probe(ctx context.Context, cfg Config) (time.Duration, error) {
	start := p.now()
	c, err := p.dial(ctx, cfg)
	elapsed := p.now().Sub(start)
	if err != nil {
		return elapsed, err
	}
	if c != nil {
		_ = c.Close()
	}
	return elapsed, nil
}

// Close 关闭并移除指定服务器的连接。
func (p *Pool) Close(serverID int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if e, ok := p.entries[serverID]; ok {
		_ = e.client.Close()
		delete(p.entries, serverID)
	}
}

// CloseAll 关闭全部连接。
func (p *Pool) CloseAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for id, e := range p.entries {
		_ = e.client.Close()
		delete(p.entries, id)
	}
}

// Reap 把空闲超过 idleTTL 的连接标记为 stale，返回标记数量。
//
// 刻意**不在这里关闭**：池中没有「会话是否在途」的信息，而 apt 全量升级、
// docker logs -f、大文件传输可能持续十几分钟以上，仅凭 lastUsed 关闭会把
// 这些任务静默腰斩（任务中断且不留明确报错）。标记后由下一次 Get 关闭旧连接
// 并重建；进程退出走 CloseAll，删服务器走 Close。
//
// 代价是长期不用的连接会占着 socket，直到下次访问或进程退出。个人面板的
// 连接数是服务器数量级，这个代价远小于「长任务被腰斩」。
func (p *Pool) Reap() int {
	p.mu.Lock()
	defer p.mu.Unlock()

	cutoff := p.now().Add(-p.idleTTL)
	n := 0
	for _, e := range p.entries {
		if e.stale || !e.lastUsed.Before(cutoff) {
			continue
		}
		e.stale = true
		n++
	}
	return n
}

// Len 返回当前缓存的连接数。
func (p *Pool) Len() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.entries)
}

// keepAliveTimeout 是存活探测的上限。
//
// SendRequest 是同步阻塞的：连接被 NAT/Tailscale 静默丢弃（TCP 半开）时，
// 它会一直等到内核重传超时（可达数分钟）。探测必须在池锁之外做，否则一次
// 卡住会让所有机器的请求一起排队——表现为「面板卡住、所有机器一起掉线」。
// 超时即判定连接不可用并主动关闭，让下次调用重建。
const keepAliveTimeout = 5 * time.Second

func (p *Pool) probeAlive(c *ssh.Client) bool {
	if c == nil {
		return false
	}
	done := make(chan error, 1)
	go func() {
		_, _, err := c.SendRequest("keepalive@openssh.com", true, nil)
		done <- err
	}()
	select {
	case err := <-done:
		// ok=false（服务端不支持该请求）仍算存活，只看传输层错误
		return err == nil
	case <-time.After(keepAliveTimeout):
		_ = c.Close()
		return false
	}
}
