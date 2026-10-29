package db

import (
	"testing"
	"time"
)

func TestInsertAndQueryMetrics(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	if err := InsertMetric(d, 1, 10, 20, 30, 0.5); err != nil {
		t.Fatal(err)
	}
	if err := InsertMetric(d, 1, 15, 25, 35, 0.6); err != nil {
		t.Fatal(err)
	}

	list, err := QueryMetrics(d, 1, time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatalf("QueryMetrics: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("len=%d, want 2", len(list))
	}

	latest, err := LatestMetric(d, 1)
	if err != nil || latest == nil {
		t.Fatalf("LatestMetric: %v %v", latest, err)
	}
	if latest.CPUPct != 15 {
		t.Errorf("latest=%+v", latest)
	}
}

func TestLatestMetricEmpty(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	m, err := LatestMetric(d, 999)
	if err != nil || m != nil {
		t.Errorf("无数据应返回 nil,nil，实际 %v %v", m, err)
	}
}

func TestPruneMetrics(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	if err := InsertMetric(d, 1, 1, 1, 1, 1); err != nil {
		t.Fatal(err)
	}
	n, err := PruneMetrics(d, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatalf("PruneMetrics: %v", err)
	}
	if n != 1 {
		t.Errorf("deleted=%d, want 1", n)
	}
}

// 降采样：同一桶内多条取均值，跨桶分开；桶边界按 since 对齐。
func TestQueryMetricsDownsampled(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	insert := func(ts string, cpu float64) {
		t.Helper()
		if _, err := d.Exec(
			`INSERT INTO server_metrics(server_id, ts, cpu_pct, mem_pct, disk_pct, load1) VALUES (1,?,?,?,?,?)`,
			ts, cpu, cpu+10, cpu+20, 0.5,
		); err != nil {
			t.Fatalf("insert %s: %v", ts, err)
		}
	}
	insert("2026-10-29 00:00:10", 10)
	insert("2026-10-29 00:00:20", 30)
	insert("2026-10-29 00:06:00", 50)

	since := time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC)
	list, err := QueryMetricsDownsampled(d, 1, since, 300)
	if err != nil {
		t.Fatalf("QueryMetricsDownsampled: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("桶数=%d, want 2（10s 与 20s 同桶，6min 另起一桶）", len(list))
	}
	// 首桶是 AVG(10,30)=20，不是 SUM(40)：缺采样时不该补零，AVG 才反映真实均值。
	if list[0].CPUPct != 20 {
		t.Errorf("首桶 cpu=%v, want 20", list[0].CPUPct)
	}
	if list[1].CPUPct != 50 {
		t.Errorf("次桶 cpu=%v, want 50", list[1].CPUPct)
	}
	if list[0].TS.After(list[1].TS) {
		t.Errorf("应按时间升序：%v > %v", list[0].TS, list[1].TS)
	}
}

// 降采样的列顺序必须与 scanMetric 对齐（9 列），否则会静默错位。
func TestQueryMetricsDownsampledColumnOrder(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	if _, err := d.Exec(
		`INSERT INTO server_metrics(server_id, ts, cpu_pct, mem_pct, disk_pct, load1, net_in_kbps, net_out_kbps)
		 VALUES (7,'2026-10-29 01:00:00',11,22,33,0.7,100,200)`,
	); err != nil {
		t.Fatalf("insert: %v", err)
	}
	since := time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC)
	list, err := QueryMetricsDownsampled(d, 7, since, 300)
	if err != nil {
		t.Fatalf("QueryMetricsDownsampled: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("len=%d, want 1", len(list))
	}
	m := list[0]
	if m.ServerID != 7 || m.CPUPct != 11 || m.MemPct != 22 || m.DiskPct != 33 || m.Load1 != 0.7 ||
		m.NetIn != 100 || m.NetOut != 200 {
		t.Errorf("列错位：%+v", m)
	}
}
