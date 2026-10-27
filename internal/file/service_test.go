package file

import (
	"crypto/ed25519"
	"crypto/rand"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

// startTestSFTP 在本地内存中启动一个 SFTP 服务端，返回客户端连接与临时根目录。
// 用于在没有外部 SSH 服务的情况下验证写入语义（覆盖、权限、临时文件清理）。
func startTestSFTP(t *testing.T) (*sftp.Client, string) {
	t.Helper()

	dir := t.TempDir()

	sshCfg := &ssh.ServerConfig{NoClientAuth: true}
	sshCfg.AddHostKey(generateTestHostKey(t))

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go serveSFTPConn(conn, sshCfg)
		}
	}()

	clientCfg := &ssh.ClientConfig{
		User:            "test",
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	}
	conn, err := ssh.Dial("tcp", listener.Addr().String(), clientCfg)
	if err != nil {
		t.Fatalf("SSH 拨号失败: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	client, err := sftp.NewClient(conn)
	if err != nil {
		t.Fatalf("SFTP 客户端创建失败: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })

	return client, dir
}

func serveSFTPConn(conn net.Conn, cfg *ssh.ServerConfig) {
	sshConn, chans, reqs, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		_ = conn.Close()
		return
	}
	go ssh.DiscardRequests(reqs)
	for newChan := range chans {
		if newChan.ChannelType() != "session" {
			_ = newChan.Reject(ssh.UnknownChannelType, "仅支持 session")
			continue
		}
		ch, chReqs, err := newChan.Accept()
		if err != nil {
			continue
		}
		go func(ch ssh.Channel, chReqs <-chan *ssh.Request) {
			for req := range chReqs {
				ok := req.Type == "subsystem" && len(req.Payload) > 4 && string(req.Payload[4:]) == "sftp"
				if req.WantReply {
					_ = req.Reply(ok, nil)
				}
				if ok {
					server, err := sftp.NewServer(ch)
					if err != nil {
						_ = ch.Close()
						return
					}
					_ = server.Serve()
					_ = server.Close()
					return
				}
			}
			_ = ch.Close()
		}(ch, chReqs)
	}
	_ = sshConn.Close()
}

func generateTestHostKey(t *testing.T) ssh.Signer {
	t.Helper()
	// 用 ed25519 生成临时主机密钥（测试专用，不入库）。
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("生成主机密钥失败: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatalf("构造 signer 失败: %v", err)
	}
	return signer
}

// TestWriteAtomicOverwriteExisting 验证覆盖已存在文件时写入成功、
// 权限与属主保留、且不残留临时文件。
func TestWriteAtomicOverwriteExisting(t *testing.T) {
	client, dir := startTestSFTP(t)

	p := filepath.Join(dir, "app.conf")
	if err := os.WriteFile(p, []byte("old\n"), 0o640); err != nil {
		t.Fatalf("准备初始文件失败: %v", err)
	}

	if err := WriteAtomic(client, p, "new content\n"); err != nil {
		t.Fatalf("覆盖写入失败: %v", err)
	}

	got, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("读取结果失败: %v", err)
	}
	if string(got) != "new content\n" {
		t.Fatalf("内容应为 %q，实际 %q", "new content\n", string(got))
	}

	fi, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat 失败: %v", err)
	}
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("权限应保留 0640，实际 %o", fi.Mode().Perm())
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("读取目录失败: %v", err)
	}
	for _, e := range entries {
		if e.Name() != "app.conf" {
			t.Fatalf("不应残留临时文件，实际多出 %q", e.Name())
		}
	}
}

// TestWriteAtomicNewFile 验证写入新文件。
func TestWriteAtomicNewFile(t *testing.T) {
	client, dir := startTestSFTP(t)

	p := filepath.Join(dir, "new.yaml")
	if err := WriteAtomic(client, p, "services: {}\n"); err != nil {
		t.Fatalf("写入新文件失败: %v", err)
	}

	got, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("读取失败: %v", err)
	}
	if string(got) != "services: {}\n" {
		t.Fatalf("内容不符，实际 %q", string(got))
	}
}
