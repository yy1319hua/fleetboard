package monitor

import (
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/ssh"

	"github.com/yy1319hua/fleetboard/internal/model"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// factsScript 采集主机静态配置，输出 KEY=VALUE 行（DISK 行带 6 个竖线分隔字段）。
//
// 三条约束（都是为了不同发行版上都能跑通）：
//  1. 全部走 /bin/sh（sshpool.PrepareScript），不依赖账号登录 shell——zsh 下
//     `set -- $a $b` 不分词的问题已在指标采集上踩过一次；
//  2. 不 source /etc/os-release，改用 awk 解析，避免子 shell 退出码与引号差异；
//  3. 每条命令都吞掉 stderr 并给空值兜底：缺 systemd-detect-virt、缺 /proc/cpuinfo
//     的容器里也要能出结果，宁可字段为空也不要整段失败。
const factsScript = `cpu_model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
[ -z "$cpu_model" ] && cpu_model=$(awk -F': ' '/^Model/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
[ -z "$cpu_model" ] && cpu_model=$(awk -F': ' '/^Hardware/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
[ -z "$cores" ] && cores=0
mem=$(awk '/^MemTotal/{print $2; exit}' /proc/meminfo 2>/dev/null)
swap=$(awk '/^SwapTotal/{print $2; exit}' /proc/meminfo 2>/dev/null)
os_name=$(awk -F= '/^PRETTY_NAME=/{v=$2; gsub(/"/,"",v); print v; exit}' /etc/os-release 2>/dev/null)
[ -z "$os_name" ] && os_name=$(uname -s 2>/dev/null)
kernel=$(uname -r 2>/dev/null)
arch=$(uname -m 2>/dev/null)
host=$(cat /proc/sys/kernel/hostname 2>/dev/null)
up=$(awk '{print int($1); exit}' /proc/uptime 2>/dev/null)
virt=$(systemd-detect-virt 2>/dev/null)
[ -z "$virt" ] && virt=unknown
printf 'CPU_MODEL=%s\n' "$cpu_model"
printf 'CPU_CORES=%s\n' "$cores"
printf 'MEM_TOTAL_KB=%s\n' "$mem"
printf 'SWAP_TOTAL_KB=%s\n' "$swap"
printf 'OS=%s\n' "$os_name"
printf 'KERNEL=%s\n' "$kernel"
printf 'ARCH=%s\n' "$arch"
printf 'HOSTNAME=%s\n' "$host"
printf 'UPTIME_SEC=%s\n' "$up"
printf 'VIRT=%s\n' "$virt"
root_fs=$(stat -c %d / 2>/dev/null)
df -P -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null \
  | awk 'NR>1 && $2+0>0 && $6 ~ /^\// && !seen[$1 "|" $2]++ {print $1 "|" $6 "|" $2 "|" $3 "|" $4 "|" $5}' \
  | while IFS='|' read -r dev mnt tot used avail pct; do
      [ -d "$mnt" ] || continue
      # 与 / 同一文件系统的挂载点跳过：避免把同一块盘的 bind mount 重复列出。
      # 容器运行时内部挂载（overlay / /var/lib/docker/...）的 st_dev 与 / 不同，
      # 这一层挡不住，由 ParseFacts 侧的 isVirtualMount 过滤。
      fs=$(stat -c %d "$mnt" 2>/dev/null)
      if [ -n "$fs" ] && [ "$fs" = "$root_fs" ] && [ "$mnt" != "/" ]; then continue; fi
      printf 'DISK=%s|%s|%s|%s|%s|%s\n' "$dev" "$mnt" "$tot" "$used" "$avail" "$pct"
    done`

// CollectFacts 采集一台主机的静态配置。
func CollectFacts(cli *ssh.Client) (*model.ServerFacts, error) {
	sess, err := cli.NewSession()
	if err != nil {
		return nil, err
	}
	defer func() { _ = sess.Close() }()

	out, err := sess.Output(sshpool.PrepareScript(sess, factsScript))
	if err != nil {
		return nil, err
	}
	return ParseFacts(string(out))
}

// ParseFacts 解析 factsScript 的输出。
//
// 容错原则：单个字段缺失只让该字段为空/零，不整体报错；但如果一条可用信息都没
// 解析出来（例如脚本被截断、远端返回空），视为失败——空快照会把概览的配置卡
// 写成一片「—」，比报错更难排查。
func ParseFacts(out string) (*model.ServerFacts, error) {
	f := &model.ServerFacts{Disks: []model.DiskUsage{}}
	got := 0

	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		val = strings.TrimSpace(val)

		switch key {
		case "CPU_MODEL":
			f.CPUModel = val
		case "CPU_CORES":
			f.CPUCores = atoiOr0(val)
		case "MEM_TOTAL_KB":
			f.MemTotalKB = int64(atoiOr0(val))
		case "SWAP_TOTAL_KB":
			f.SwapTotalKB = int64(atoiOr0(val))
		case "OS":
			f.OSName = val
		case "KERNEL":
			f.Kernel = val
		case "ARCH":
			f.Arch = val
		case "HOSTNAME":
			f.Hostname = val
		case "UPTIME_SEC":
			f.UptimeSec = int64(atoiOr0(val))
		case "VIRT":
			f.Virt = val
		case "DISK":
			if d, ok := parseDisk(val); ok && !isVirtualMount(d) {
				f.Disks = append(f.Disks, d)
			}
		default:
			continue
		}
		got++
	}

	if got == 0 {
		return nil, fmt.Errorf("配置采集输出无法解析（%q）", truncate(out, 120))
	}
	return f, nil
}

// parseDisk 解析 "device|mount|total_kb|used_kb|avail_kb|used_pct"。
func parseDisk(s string) (model.DiskUsage, bool) {
	parts := strings.Split(s, "|")
	if len(parts) != 6 {
		return model.DiskUsage{}, false
	}
	pct := strings.TrimSuffix(strings.TrimSpace(parts[5]), "%")
	return model.DiskUsage{
		Device:  strings.TrimSpace(parts[0]),
		Mount:   strings.TrimSpace(parts[1]),
		TotalKB: int64(atoiOr0(parts[2])),
		UsedKB:  int64(atoiOr0(parts[3])),
		AvailKB: int64(atoiOr0(parts[4])),
		UsedPct: atofOr0(pct),
	}, true
}

// virtualDevices 是容器/虚拟文件系统在 df 里的设备名，不是块设备。
var virtualDevices = map[string]bool{
	"overlay": true, "none": true, "shm": true, "udev": true, "rootfs": true,
}

// virtualMountPrefixes 是容器运行时自身的内部挂载目录。
//
// 带尾部斜杠：`/var/lib/docker` 本身若是一块独立分区，那是真实挂载点，要保留；
// 只有它下面的容器 rootfs（`/var/lib/docker/rootfs/overlayfs/<id>`）才排除。
var virtualMountPrefixes = []string{
	"/var/lib/docker/", "/var/lib/containers/", "/snap/",
}

// isVirtualMount 判断挂载点是否为容器运行时内部产物。
//
// 为什么必须过滤：装了 Docker 且跑着容器的机器上，df 会把每个容器的 rootfs
// 列成 `overlay → /var/lib/docker/rootfs/overlayfs/<64 位 id>`。它的容量与宿主
// 盘完全相同，保留就等于把同一块盘重复显示一遍，而且那串几十字符的路径会把
// 概览卡撑成一堆省略号——用户会以为多了块盘。
//
// 只按名字判断的原因：overlay 的 st_dev 与 / 不同，脚本侧的 stat 比对挡不住。
func isVirtualMount(d model.DiskUsage) bool {
	if virtualDevices[d.Device] {
		return true
	}
	for _, p := range virtualMountPrefixes {
		if strings.HasPrefix(d.Mount, p) {
			return true
		}
	}
	return false
}

func atoiOr0(s string) int {
	v, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0
	}
	return v
}

func atofOr0(s string) float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil {
		return 0
	}
	return v
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
