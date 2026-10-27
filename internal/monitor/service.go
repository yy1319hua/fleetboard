// Package monitor 负责主机指标采集与查询。
package monitor

import (
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/ssh"
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

// Collect 采样一台主机的指标。
func Collect(cli *ssh.Client) (*Snapshot, error) {
	sess, err := cli.NewSession()
	if err != nil {
		return nil, err
	}
	defer func() { _ = sess.Close() }()

	out, err := sess.Output(metricsScript)
	if err != nil {
		return nil, err
	}
	return ParseMetricsLine(string(out))
}
