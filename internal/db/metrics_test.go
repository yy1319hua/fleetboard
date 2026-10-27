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
