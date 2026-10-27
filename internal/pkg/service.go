// Package pkg 负责被管机系统软件包更新（仅 Debian/Ubuntu 系 apt）。
package pkg

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"strings"
	"sync"

	"golang.org/x/crypto/ssh"
)

// UpdateCommand 是固定的更新命令：
//   - DEBIAN_FRONTEND=noninteractive：避免升级途中等交互输入而挂住
//   - confdef/confold：配置文件冲突时保留现有配置，不弹问
//
// 命令为常量，不接受任何用户输入拼接。
const UpdateCommand = `export DEBIAN_FRONTEND=noninteractive; ` +
	`apt-get update && ` +
	`apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade`

// Upgrade 在被管机执行 apt 更新，逐行回调输出（stdout+stderr 合并）。
// ctx 取消时向远端进程发送 SIGINT 中断，并关闭会话兜底。
func Upgrade(ctx context.Context, cli *ssh.Client, onLine func(string)) error {
	if onLine == nil {
		onLine = func(string) {}
	}

	sess, err := cli.NewSession()
	if err != nil {
		return fmt.Errorf("创建 SSH 会话失败: %w", err)
	}
	defer func() { _ = sess.Close() }()

	stdout, err := sess.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := sess.StderrPipe()
	if err != nil {
		return err
	}

	if err := sess.Start(UpdateCommand); err != nil {
		return fmt.Errorf("启动 apt 失败: %w", err)
	}

	// 取消 → SIGINT 中断远端 apt，再关会话兜底
	stop := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = sess.Signal(ssh.SIGINT)
			_ = sess.Close()
		case <-stop:
		}
	}()

	var (
		mu sync.Mutex
		wg sync.WaitGroup
	)
	emit := func(line string) {
		mu.Lock()
		onLine(line)
		mu.Unlock()
	}

	wg.Add(2)
	go func() { defer wg.Done(); PumpLines(stdout, emit) }()
	go func() { defer wg.Done(); PumpLines(stderr, emit) }()
	wg.Wait()

	err = sess.Wait()
	close(stop)

	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		return fmt.Errorf("apt 更新失败: %w", err)
	}
	return nil
}

// PumpLines 逐行读取输出并回调（去掉行尾 \r，支持最长 1MiB 的单行）。
func PumpLines(r io.Reader, emit func(string)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		emit(strings.TrimRight(sc.Text(), "\r"))
	}
}
