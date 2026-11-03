package alert

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
)

func openAlertDB(t *testing.T) *sql.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "alert.db"))
	if err != nil {
		t.Fatalf("打开测试库: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func countEvents(t *testing.T, d *sql.DB) int {
	t.Helper()
	var n int
	if err := d.QueryRow(`SELECT COUNT(1) FROM alert_events`).Scan(&n); err != nil {
		t.Fatalf("统计告警事件: %v", err)
	}
	return n
}

func TestEngineSuppressesRepeatedHits(t *testing.T) {
	d := openAlertDB(t)
	sid := int64(1)
	if _, err := db.CreateAlertRule(d, db.AlertRuleInput{
		ServerID: &sid, Metric: "cpu_pct", Operator: ">", Threshold: 80,
		Severity: "warn", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}

	base := time.Now()
	e := NewEngine(10 * time.Minute)
	e.now = func() time.Time { return base }
	m := &model.ServerMetric{CPUPct: 95}

	for i := 0; i < 5; i++ {
		if _, err := e.Evaluate(d, sid, m, ""); err != nil {
			t.Fatalf("第 %d 轮评估: %v", i+1, err)
		}
	}
	if n := countEvents(t, d); n != 1 {
		t.Errorf("冷却期内应只入库 1 条，实际 %d", n)
	}

	// 冷却到期后应再报一次
	base = base.Add(11 * time.Minute)
	e.now = func() time.Time { return base }
	if _, err := e.Evaluate(d, sid, m, ""); err != nil {
		t.Fatalf("冷却后评估: %v", err)
	}
	if n := countEvents(t, d); n != 2 {
		t.Errorf("冷却到期后应累计 2 条，实际 %d", n)
	}
}

func TestEngineOfflineRuleFires(t *testing.T) {
	d := openAlertDB(t)
	sid := int64(2)
	if _, err := db.CreateAlertRule(d, db.AlertRuleInput{
		ServerID: &sid, Metric: "offline", Operator: "=", Threshold: 1,
		Severity: "critical", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}

	base := time.Now()
	e := NewEngine(10 * time.Minute)
	e.now = func() time.Time { return base }

	// 指标类评估不应触发 offline 规则
	if _, err := e.Evaluate(d, sid, &model.ServerMetric{CPUPct: 1}, ""); err != nil {
		t.Fatal(err)
	}
	if n := countEvents(t, d); n != 0 {
		t.Fatalf("offline 规则不应由指标评估触发，实际 %d 条", n)
	}

	if _, err := e.EvaluateOffline(d, sid, ""); err != nil {
		t.Fatal(err)
	}
	if n := countEvents(t, d); n != 1 {
		t.Fatalf("离线应产生 1 条告警，实际 %d", n)
	}

	// 同一轮失败重复调用（每轮都会跨过阈值）：冷却内不重复
	if _, err := e.EvaluateOffline(d, sid, ""); err != nil {
		t.Fatal(err)
	}
	if n := countEvents(t, d); n != 1 {
		t.Errorf("冷却期内离线告警不应重复，实际 %d", n)
	}

	// 恢复在线后复位，再次离线应立刻再报
	e.ClearOffline(sid)
	if _, err := e.EvaluateOffline(d, sid, ""); err != nil {
		t.Fatal(err)
	}
	if n := countEvents(t, d); n != 2 {
		t.Errorf("复位后再离线应立即再报，累计应为 2，实际 %d", n)
	}
}
