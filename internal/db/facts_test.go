package db

import (
	"database/sql"
	"testing"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// insertTestServer 建一台占位服务器：server_facts.server_id 有外键约束，
// 不先建主表行，写入会直接 FOREIGN KEY constraint failed。
func insertTestServer(t *testing.T, d *sql.DB, id int64) {
	t.Helper()
	if _, err := d.Exec(
		`INSERT INTO servers(id, name, host, port, ssh_user, auth_method, connection_status)
		 VALUES(?, ?, '192.0.2.1', 22, 'root', 'key', 'unknown')`,
		id, "node-test",
	); err != nil {
		t.Fatalf("插入服务器 #%d: %v", id, err)
	}
}

func TestUpsertAndGetFacts(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	insertTestServer(t, d, 7)

	in := &model.ServerFacts{
		ServerID:    7,
		CPUModel:    "AMD Ryzen 7 5800X 8-Core Processor",
		CPUCores:    16,
		MemTotalKB:  33554432,
		SwapTotalKB: 8388608,
		OSName:      "Debian GNU/Linux 12 (bookworm)",
		Kernel:      "6.1.0-13-amd64",
		Arch:        "x86_64",
		Hostname:    "node-a",
		UptimeSec:   86400,
		Virt:        "kvm",
		Disks: []model.DiskUsage{
			{Device: "/dev/sda1", Mount: "/", TotalKB: 100, UsedKB: 40, AvailKB: 60, UsedPct: 40},
			{Device: "/dev/sdb1", Mount: "/data", TotalKB: 200, UsedKB: 10, AvailKB: 190, UsedPct: 5},
		},
	}
	if err := UpsertFacts(d, in); err != nil {
		t.Fatalf("UpsertFacts: %v", err)
	}

	got, err := GetFacts(d, 7)
	if err != nil || got == nil {
		t.Fatalf("GetFacts: %v %v", got, err)
	}
	if got.CPUModel != in.CPUModel || got.CPUCores != 16 || got.MemTotalKB != in.MemTotalKB {
		t.Errorf("标量字段不一致: %+v", got)
	}
	if len(got.Disks) != 2 || got.Disks[1].Mount != "/data" || got.Disks[1].UsedPct != 5 {
		t.Errorf("磁盘列表往返失败: %+v", got.Disks)
	}
	if got.CollectedAt.IsZero() {
		t.Error("collected_at 未写入")
	}
}

func TestUpsertFactsOverwrites(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	insertTestServer(t, d, 3)

	if err := UpsertFacts(d, &model.ServerFacts{ServerID: 3, CPUModel: "old", CPUCores: 2}); err != nil {
		t.Fatal(err)
	}
	if err := UpsertFacts(d, &model.ServerFacts{ServerID: 3, CPUModel: "new", CPUCores: 8, OSName: "Ubuntu 24.04"}); err != nil {
		t.Fatal(err)
	}

	got, err := GetFacts(d, 3)
	if err != nil || got == nil {
		t.Fatalf("GetFacts: %v %v", got, err)
	}
	if got.CPUModel != "new" || got.CPUCores != 8 || got.OSName != "Ubuntu 24.04" {
		t.Errorf("覆盖写入未生效: %+v", got)
	}

	var n int
	if err := d.QueryRow(`SELECT COUNT(1) FROM server_facts WHERE server_id = 3`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("应为一行，实际 %d 行", n)
	}
}

func TestGetFactsMissing(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	f, err := GetFacts(d, 999)
	if err != nil || f != nil {
		t.Errorf("未采集应返回 nil,nil，实际 %v %v", f, err)
	}
}

// 删除服务器后配置行必须跟着走：否则重新纳管同一 id 时会先闪出上一台机器的
// CPU 型号与磁盘，比空白更误导。
func TestFactsCascadeOnServerDelete(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	if _, err := d.Exec(
		`INSERT INTO servers(id, name, host, port, ssh_user, auth_method, connection_status)
		 VALUES(9, 'node-x', '192.0.2.9', 22, 'root', 'key', 'unknown')`,
	); err != nil {
		t.Fatalf("插入服务器: %v", err)
	}
	if err := UpsertFacts(d, &model.ServerFacts{ServerID: 9, CPUModel: "stale"}); err != nil {
		t.Fatalf("UpsertFacts: %v", err)
	}

	if err := DeleteServer(d, 9); err != nil {
		t.Fatalf("DeleteServer: %v", err)
	}

	var n int
	if err := d.QueryRow(`SELECT COUNT(1) FROM server_facts WHERE server_id = 9`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("删除服务器后仍有 %d 行配置残留", n)
	}
}

// 配置重采不能把能力检测结果抹掉。
//
// 这两条写入路径是分开的：采集循环只调 UpsertFacts，体检测完能力才调
// UpdateCapabilities。如果 UpsertFacts 顺手写了 has_docker/has_sftp，
// 一次配置重采就会把「没有 Docker」的判断冲成未检测，容器 Tab 会突然回来。
func TestUpsertFactsKeepsCapabilities(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	insertTestServer(t, d, 11)

	if err := UpsertFacts(d, &model.ServerFacts{ServerID: 11, CPUModel: "Xeon"}); err != nil {
		t.Fatalf("UpsertFacts: %v", err)
	}
	// 新行默认三态为「未检测」。
	got, err := GetFacts(d, 11)
	if err != nil || got == nil {
		t.Fatalf("GetFacts: %v %v", got, err)
	}
	if got.HasDocker != -1 || got.HasSFTP != -1 {
		t.Errorf("新行能力应默认 -1，实际 docker=%d sftp=%d", got.HasDocker, got.HasSFTP)
	}

	if err := UpdateCapabilities(d, 11, 1, 0); err != nil {
		t.Fatalf("UpdateCapabilities: %v", err)
	}
	// 再采一次配置（模拟采集循环或手动刷新）。
	if err := UpsertFacts(d, &model.ServerFacts{ServerID: 11, CPUModel: "Xeon v2"}); err != nil {
		t.Fatalf("UpsertFacts 二次: %v", err)
	}

	got, err = GetFacts(d, 11)
	if err != nil || got == nil {
		t.Fatalf("GetFacts 二次: %v %v", got, err)
	}
	if got.HasDocker != 1 || got.HasSFTP != 0 {
		t.Errorf("配置重采覆盖了能力列：docker=%d sftp=%d", got.HasDocker, got.HasSFTP)
	}
	if got.ProbedAt == nil {
		t.Error("probed_at 未写入")
	}
	if got.CPUModel != "Xeon v2" {
		t.Errorf("配置没更新：%q", got.CPUModel)
	}
}

// 只有配置行存在时能力才存得下；没有行时不该报错，等下次体检重来。
func TestUpdateCapabilitiesWithoutFactsRow(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()
	insertTestServer(t, d, 12)

	if err := UpdateCapabilities(d, 12, 1, 1); err != nil {
		t.Errorf("无配置行时不应报错: %v", err)
	}
	got, err := GetFacts(d, 12)
	if err != nil || got != nil {
		t.Errorf("未采配置时应仍为 nil，实际 %v %v", got, err)
	}
}
