package monitor

import (
	"testing"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// 真实 armbian（zsh 机器）上的输出形态，含两个挂载点。
const factsSample = `CPU_MODEL=ARMv8 Processor rev 1 (v8l)
CPU_CORES=4
MEM_TOTAL_KB=3938308
SWAP_TOTAL_KB=0
OS=Armbian 24.11.1 bookworm
KERNEL=6.6.44-current-rockchip64
ARCH=aarch64
HOSTNAME=armbian
UPTIME_SEC=812345
VIRT=docker
DISK=/dev/mmcblk0p1|/|30442432|5832116|24610316|20%
DISK=/dev/sda1|/data|961301832|120000|961181832|1%
`

func TestParseFacts(t *testing.T) {
	f, err := ParseFacts(factsSample)
	if err != nil {
		t.Fatalf("ParseFacts: %v", err)
	}
	if f.CPUModel != "ARMv8 Processor rev 1 (v8l)" {
		t.Errorf("CPUModel=%q", f.CPUModel)
	}
	if f.CPUCores != 4 || f.MemTotalKB != 3938308 || f.UptimeSec != 812345 {
		t.Errorf("数值字段错误: %+v", f)
	}
	if f.Arch != "aarch64" || f.Virt != "docker" || f.OSName != "Armbian 24.11.1 bookworm" {
		t.Errorf("字符串字段错误: %+v", f)
	}
	if len(f.Disks) != 2 {
		t.Fatalf("disks=%d, want 2", len(f.Disks))
	}
	if f.Disks[0].Mount != "/" || f.Disks[0].UsedPct != 20 || f.Disks[0].TotalKB != 30442432 {
		t.Errorf("第一个挂载点解析错误: %+v", f.Disks[0])
	}
	if f.Disks[1].Mount != "/data" || f.Disks[1].UsedPct != 1 {
		t.Errorf("第二个挂载点解析错误: %+v", f.Disks[1])
	}
}

// 缺字段、坏行都不应整体失败：容器里没有 systemd-detect-virt、disk 行被截断是常态。
func TestParseFactsToleratesGaps(t *testing.T) {
	out := "OS=Alpine Linux v3.20\nARCH=x86_64\nDISK=/dev/sda1|/\n\nCPU_CORES=not-a-number\n"
	f, err := ParseFacts(out)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if f.OSName != "Alpine Linux v3.20" || f.Arch != "x86_64" {
		t.Errorf("%+v", f)
	}
	if f.CPUCores != 0 {
		t.Errorf("非法数字应归零，实际 %d", f.CPUCores)
	}
	if len(f.Disks) != 0 {
		t.Errorf("字段数不足的 DISK 行应被跳过，实际 %+v", f.Disks)
	}
	if f.Disks == nil {
		t.Error("disks 应为空切片而非 nil，避免 JSON 输出成 null")
	}
}

func TestParseFactsEmptyIsError(t *testing.T) {
	if _, err := ParseFacts(""); err == nil {
		t.Error("空输出应报错，否则会把空白快照写进库")
	}
	if _, err := ParseFacts("\n\n  \n"); err == nil {
		t.Error("纯空白应报错")
	}
}

// 装了 Docker 的宿主机上，df 会把每个容器的 rootfs 列成
// `overlay → /var/lib/docker/rootfs/overlayfs/<id>`，容量与宿主盘完全相同。
// 保留就会把同一块盘重复显示，且几十字符路径把界面撑坏。
func TestParseFactsSkipsContainerMounts(t *testing.T) {
	out := `CPU_MODEL=AMD EPYC 7551 32-Core Processor
CPU_CORES=2
ARCH=x86_64
DISK=/dev/sda1|/|46212176|7841548|38354244|17%
DISK=/dev/sda15|/boot/efi|106832|6250|100582|6%
DISK=overlay|/var/lib/docker/rootfs/overlayfs/f9e5ad4d17f5ec8036ddbac45baacd297326ba6ee3ce6a77e278963fe3920e5d|46212176|7841548|38354244|17%
DISK=shm|/dev/shm|65536|0|65536|0%
DISK=/dev/sdb1|/snap/core/1234|102400|102400|0|100%
`
	f, err := ParseFacts(out)
	if err != nil {
		t.Fatalf("ParseFacts: %v", err)
	}
	if len(f.Disks) != 2 {
		t.Fatalf("应只保留 2 个真实挂载点，实际 %d 个: %+v", len(f.Disks), f.Disks)
	}
	if f.Disks[0].Mount != "/" || f.Disks[1].Mount != "/boot/efi" {
		t.Errorf("保留的挂载点不对: %+v", f.Disks)
	}
}

// /var/lib/docker 若被单独分出来，是真实分区，必须保留；只有它下面的容器
// rootfs 才排除。带不带尾部斜杠就是这个区别。
func TestIsVirtualMountKeepsDockerPartition(t *testing.T) {
	if isVirtualMount(model.DiskUsage{Device: "/dev/sdc1", Mount: "/var/lib/docker"}) {
		t.Error("/var/lib/docker 作为独立分区时应保留")
	}
	if !isVirtualMount(model.DiskUsage{Device: "overlay", Mount: "/var/lib/docker"}) {
		t.Error("设备名为 overlay 时应排除，与挂载点无关")
	}
	if !isVirtualMount(model.DiskUsage{Device: "/dev/sdc1", Mount: "/var/lib/docker/overlay2/abc"}) {
		t.Error("容器内部目录应排除")
	}
}
