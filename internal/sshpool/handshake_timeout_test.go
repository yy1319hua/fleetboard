package sshpool

import (
	"context"
	"net"
	"testing"
	"time"
)

// 服务端收下 TCP 却不发 SSH banner 时，DefaultDialer 必须在超时内返回。
//
// 这条路径过去会永久阻塞：ssh.NewClientConn 一直等对端 version 字符串，
// 而 ClientConfig.Timeout 对它无效。后果是拨号协程泄漏、socket 半死挂在
// ESTAB，并把 p.dialing 里的条目永久占住，该机器在进程重启前全部超时。
func TestDefaultDialerHandshakeTimeout(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	stop := make(chan struct{})
	defer close(stop)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		<-stop // 只 accept，不说话
	}()

	addr := ln.Addr().(*net.TCPAddr)
	// 调用方给 400ms，比 handshakeTimeout 更紧，应被优先采用。
	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()

	start := time.Now()
	cli, err := DefaultDialer(ctx, Config{
		Host:       "127.0.0.1",
		Port:       addr.Port,
		User:       "tester",
		AuthMethod: "password",
		Password:   "secret",
	})
	elapsed := time.Since(start)
	if cli != nil {
		_ = cli.Close()
	}

	if err == nil {
		t.Fatal("对端未回应握手却返回成功")
	}
	if elapsed > 5*time.Second {
		t.Fatalf("握手未在超时内返回，耗时 %s", elapsed)
	}
	t.Logf("按预期失败（%s）：%v", elapsed.Round(time.Millisecond), err)
}
