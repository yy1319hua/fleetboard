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
}

// Pool 按 serverID 复用 SSH 长连接，并惰性/周期清理空闲连接。
type Pool struct {
	mu      sync.Mutex
	entries map[int64]*entry
	idleTTL time.Duration
	dial    Dialer
	now     func() time.Time
}

// NewPool 创建连接池；idleTTL 为空闲连接保留时长。
func NewPool(idleTTL time.Duration) *Pool {
	return &Pool{
		entries: make(map[int64]*entry),
		idleTTL: idleTTL,
		dial:    DefaultDialer,
		now:     time.Now,
	}
}

// SetDialer 替换底层建连函数（测试用）。
func (p *Pool) SetDialer(d Dialer) { p.dial = d }

// Get 返回指定服务器可用的连接；已有连接保活失败则重建。
func (p *Pool) Get(ctx context.Context, serverID int64, cfg Config) (*ssh.Client, error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if e, ok := p.entries[serverID]; ok {
		if p.alive(e.client) {
			e.lastUsed = p.now()
			return e.client, nil
		}
		_ = e.client.Close()
		delete(p.entries, serverID)
	}

	c, err := p.dial(ctx, cfg)
	if err != nil {
		return nil, err
	}
	p.entries[serverID] = &entry{client: c, lastUsed: p.now()}
	return c, nil
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

// Reap 关闭空闲超过 idleTTL 的连接，返回关闭数量。
func (p *Pool) Reap() int {
	p.mu.Lock()
	defer p.mu.Unlock()

	cutoff := p.now().Add(-p.idleTTL)
	n := 0
	for id, e := range p.entries {
		if e.lastUsed.Before(cutoff) {
			_ = e.client.Close()
			delete(p.entries, id)
			n++
		}
	}
	return n
}

// Len 返回当前缓存的连接数。
func (p *Pool) Len() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.entries)
}

func (p *Pool) alive(c *ssh.Client) bool {
	if c == nil {
		return false
	}
	_, _, err := c.SendRequest("keepalive@openssh.com", true, nil)
	return err == nil
}
