package monitor

import "testing"

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
