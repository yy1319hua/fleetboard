// Package monitor 负责主机指标采集与查询。
package monitor

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/ssh"

	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// Snapshot 是一次主机指标采样。
type Snapshot struct {
	CPUPct  float64
	MemPct  float64
	DiskPct float64
	Load1   float64
}

// metricsScript 在远端采样：
// CPU 用两次 /proc/stat 差、内存用 MemAvailable、磁盘用 df -P /、负载取 /proc/loadavg。
const metricsScript = `a=$(awk '/^cpu /{printf "%d %d", $5, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat); sleep 0.4; b=$(awk '/^cpu /{printf "%d %d", $5, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat); set -- $a $b; idle1=$1; tot1=$2; idle2=$3; tot2=$4; dt=$((tot2-tot1)); di=$((idle2-idle1)); cpu=$(awk -v dt=$dt -v di=$di 'BEGIN{if(dt<=0)print 0; else printf "%.2f", (dt-di)*100/dt}'); mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t<=0)print 0; else printf "%.2f", (t-a)*100/t}' /proc/meminfo); disk=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}'); load=$(awk '{print $1}' /proc/loadavg); printf "%s %s %s %s\n" "$cpu" "$mem" "$disk" "$load"`

// ParseMetricsLine 解析 "cpu mem disk load" 四个数值。
func ParseMetricsLine(line string) (*Snapshot, error) {
	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) != 4 {
		return nil, fmt.Errorf("指标输出格式错误：期望 4 个字段，实际 %d（%q）", len(fields), line)
	}

	vals := make([]float64, 4)
	for i, f := range fields {
		v, err := strconv.ParseFloat(f, 64)
		if err != nil {
			return nil, fmt.Errorf("解析第 %d 个指标失败: %w", i+1, err)
		}
		vals[i] = v
	}

	return &Snapshot{
		CPUPct:  vals[0],
		MemPct:  vals[1],
		DiskPct: vals[2],
		Load1:   vals[3],
	}, nil
}

// runScript 在一条新会话上执行脚本，并保证 ctx 取消时能真正中断远端命令。
//
// 只靠 context 是不够的：ssh.Session.Output 不接受 ctx，TCP 半开时它会一直
// 阻塞到内核重传超时（可达数分钟）甚至永不返回——采集 goroutine 卡死，该机
// 从此停采、停告警，且不会自愈。这里用 Close 会话触发远端 SIGHUP，让 Output
// 尽快返回；channel 带缓冲，goroutine 不会因此泄漏。
func runScript(ctx context.Context, cli *ssh.Client, script string) ([]byte, error) {
	sess, err := cli.NewSession()
	if err != nil {
		return nil, err
	}
	defer func() { _ = sess.Close() }()

	type result struct {
		out []byte
		err error
	}
	done := make(chan result, 1)
	go func() {
		out, err := sess.Output(sshpool.PrepareScript(sess, script))
		done <- result{out: out, err: err}
	}()

	select {
	case r := <-done:
		return r.out, r.err
	case <-ctx.Done():
		_ = sess.Close()
		return nil, fmt.Errorf("脚本执行超时或被取消: %w", ctx.Err())
	}
}

// Collect 采样一台主机的指标。
//
// 脚本经 sshpool.PrepareScript 交给 /bin/sh 执行，而**不是**交给登录 shell：
// metricsScript 依赖 `set -- $a $b` 的隐式分词，在 zsh（armbian 的 root 默认）
// 下不分词，会直接报 `bad math expression`，采集 100% 失败。详见 sshpool.ShPath。
func Collect(ctx context.Context, cli *ssh.Client) (*Snapshot, error) {
	out, err := runScript(ctx, cli, metricsScript)
	if err != nil {
		return nil, err
	}
	return ParseMetricsLine(string(out))
}
