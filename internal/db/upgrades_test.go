package db

import "testing"

func TestUpgradeRecordLifecycle(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	id, err := InsertUpgradeStart(d, "v0.3.2", "v0.4.0", 7, "/var/lib/fleetboard/upgrade.log")
	if err != nil {
		t.Fatalf("InsertUpgradeStart: %v", err)
	}
	if id == 0 {
		t.Fatal("应返回记录 ID")
	}
	if err := SetUpgradeLogPath(d, id, "/var/lib/fleetboard/upgrade-1.log"); err != nil {
		t.Fatalf("SetUpgradeLogPath: %v", err)
	}
	if err := FinishUpgrade(d, id, UpgradeDone, "", 1234); err != nil {
		t.Fatalf("FinishUpgrade: %v", err)
	}

	list, err := LatestUpgrades(d, 10)
	if err != nil {
		t.Fatalf("LatestUpgrades: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("len=%d, want 1", len(list))
	}
	r := list[0]
	if r.FromVersion != "v0.3.2" || r.ToVersion != "v0.4.0" || r.Status != UpgradeDone {
		t.Errorf("字段不符: %+v", r)
	}
	if r.DurationMs != 1234 || r.LogPath != "/var/lib/fleetboard/upgrade-1.log" {
		t.Errorf("耗时/日志路径未落库: %+v", r)
	}
	if r.TriggeredBy == nil || *r.TriggeredBy != 7 {
		t.Errorf("triggered_by=%v, want 7", r.TriggeredBy)
	}
	if r.FinishedAt == nil {
		t.Error("终态应写 finished_at")
	}
	if r.StartedAt.IsZero() {
		t.Error("started_at 应由默认值填充")
	}
}

// 系统/对账路径没有触发者：triggered_by 落 NULL，序列化为 null。
func TestUpgradeRecordNoTrigger(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	id, err := InsertUpgradeStart(d, "v0.4.0", "v0.4.1", 0, "")
	if err != nil {
		t.Fatalf("InsertUpgradeStart: %v", err)
	}
	r, err := LatestInProgressUpgrade(d)
	if err != nil {
		t.Fatalf("LatestInProgressUpgrade: %v", err)
	}
	if r == nil || r.ID != id {
		t.Fatalf("应查到在途记录: %+v", r)
	}
	if r.TriggeredBy != nil {
		t.Errorf("triggered_by 应为 NULL，实际 %v", *r.TriggeredBy)
	}
}

func TestUpgradeOrderingAndPaging(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	// 同一秒内连写三条：排序必须由 (started_at DESC, id DESC) 的 id 兜底而不翻转
	var ids []int64
	for _, to := range []string{"v0.4.0", "v0.4.1", "v0.4.2"} {
		id, err := InsertUpgradeStart(d, "v0.3.2", to, 1, "")
		if err != nil {
			t.Fatalf("InsertUpgradeStart: %v", err)
		}
		ids = append(ids, id)
	}

	latest, err := LatestUpgrades(d, 2)
	if err != nil {
		t.Fatalf("LatestUpgrades: %v", err)
	}
	if len(latest) != 2 {
		t.Fatalf("len=%d, want 2（limit 生效）", len(latest))
	}
	if latest[0].ID != ids[2] || latest[1].ID != ids[1] {
		t.Errorf("应按 id DESC: %d,%d", latest[0].ID, latest[1].ID)
	}

	page, total, err := ListUpgrades(d, 2, 2)
	if err != nil {
		t.Fatalf("ListUpgrades: %v", err)
	}
	if total != 3 {
		t.Errorf("total=%d, want 3", total)
	}
	if len(page) != 1 || page[0].ID != ids[0] {
		t.Errorf("第二页应只剩最早一条: %+v", page)
	}

	// 上限收敛：limit 超 200 不应报错（内部收敛到 200）
	if _, _, err := ListUpgrades(d, 5000, 0); err != nil {
		t.Errorf("超大 limit 应收敛而非报错: %v", err)
	}
}

// 在途记录查询只认 in_progress，避免把历史终态当成「正在升级」。
func TestLatestInProgressIgnoresFinished(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	id, err := InsertUpgradeStart(d, "v0.3.2", "v0.4.0", 1, "")
	if err != nil {
		t.Fatalf("InsertUpgradeStart: %v", err)
	}
	if err := FinishUpgrade(d, id, UpgradeFailed, "verify_failed", 0); err != nil {
		t.Fatalf("FinishUpgrade: %v", err)
	}

	r, err := LatestInProgressUpgrade(d)
	if err != nil {
		t.Fatalf("LatestInProgressUpgrade: %v", err)
	}
	if r != nil {
		t.Errorf("不应返回已终态记录: %+v", r)
	}

	// 负耗时被收敛为 0，避免 UI 出现「-1ms」
	id2, _ := InsertUpgradeStart(d, "v0.3.2", "v0.4.0", 1, "")
	if err := FinishUpgrade(d, id2, UpgradeInterrupt, "", -5); err != nil {
		t.Fatalf("FinishUpgrade: %v", err)
	}
	rows, _, err := ListUpgrades(d, 1, 0)
	if err != nil {
		t.Fatalf("ListUpgrades: %v", err)
	}
	if rows[0].DurationMs != 0 {
		t.Errorf("duration_ms=%d, want 0", rows[0].DurationMs)
	}
}
