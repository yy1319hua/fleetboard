package sshpool

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"net"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// 真实协议握手，守住「服务器只提供 keyboard-interactive 时也能用密码登录」。
//
// 单测只验证了应答回调的逻辑，验证不了「客户端是否真的宣告了 keyboard-interactive」。
// 这里起一个只设 KeyboardInteractiveCallback 的服务端（等价于
// PasswordAuthentication no + KbdInteractiveAuthentication yes），再走一遍
// DefaultDialer —— 2026-11-20 的线上故障正是这条路径缺失：服务器回
// `unable to authenticate, attempted methods [none], no supported methods remain`。
func TestDialPasswordAgainstKeyboardInteractiveOnlyServer(t *testing.T) {
	addr, stop := startKeyboardInteractiveOnlyServer(t, "p@ss w0rd!#")
	defer stop()

	port := addr.Port

	t.Run("仅 ssh.Password 的旧行为会失败", func(t *testing.T) {
		cfg := &ssh.ClientConfig{
			User:            "u",
			Auth:            []ssh.AuthMethod{ssh.Password("p@ss w0rd!#")},
			HostKeyCallback: ssh.InsecureIgnoreHostKey(),
			Timeout:         3 * time.Second,
		}
		cli, err := ssh.Dial("tcp", addr.String(), cfg)
		if err == nil {
			_ = cli.Close()
			t.Fatal("服务器不支持 password 方法时，仅给 ssh.Password 不应能连上")
		}
	})

	t.Run("password + keyboard-interactive 能连上", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cli, err := DefaultDialer(ctx, Config{
			Host: "127.0.0.1", Port: port, User: "u",
			AuthMethod: "password", Password: "p@ss w0rd!#",
		})
		if err != nil {
			t.Fatalf("DefaultDialer: %v", err)
		}
		_ = cli.Close()
	})

	t.Run("密码错误仍被拒", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cli, err := DefaultDialer(ctx, Config{
			Host: "127.0.0.1", Port: port, User: "u",
			AuthMethod: "password", Password: "wrong",
		})
		if err == nil {
			_ = cli.Close()
			t.Fatal("错误密码不应通过认证")
		}
	})
}

// startKeyboardInteractiveOnlyServer 启动一个只接受 keyboard-interactive 的 SSH 服务端。
func startKeyboardInteractiveOnlyServer(t *testing.T, want string) (*net.TCPAddr, func()) {
	t.Helper()

	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("生成服务端密钥: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatalf("转换签名器: %v", err)
	}

	srvCfg := &ssh.ServerConfig{
		// 刻意不设置 PasswordCallback：服务端因此只宣告 keyboard-interactive。
		KeyboardInteractiveCallback: func(_ ssh.ConnMetadata, ch ssh.KeyboardInteractiveChallenge) (*ssh.Permissions, error) {
			answers, err := ch("", "", []string{"Password: "}, []bool{false})
			if err != nil {
				return nil, err
			}
			if len(answers) == 1 && answers[0] == want {
				return nil, nil
			}
			return nil, fmt.Errorf("密码不匹配")
		},
	}
	srvCfg.AddHostKey(signer)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听: %v", err)
	}

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				sconn, chans, reqs, err := ssh.NewServerConn(c, srvCfg)
				if err != nil {
					return
				}
				defer func() { _ = sconn.Close() }()
				go ssh.DiscardRequests(reqs)
				for nc := range chans {
					_ = nc.Reject(ssh.UnknownChannelType, "")
				}
			}()
		}
	}()

	stop := func() { _ = ln.Close() }
	return ln.Addr().(*net.TCPAddr), stop
}
