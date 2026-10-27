package alert

import (
	"testing"

	"github.com/yy1319hua/fleetboard/internal/model"
)

func TestCompare(t *testing.T) {
	cases := []struct {
		v      float64
		op     string
		th     float64
		expect bool
	}{
		{90, ">", 80, true},
		{70, ">", 80, false},
		{80, ">=", 80, true},
		{70, "<", 80, true},
		{80, "<=", 80, true},
		{80, "=", 80, true},
		{81, "=", 80, false},
		{90, "weird", 80, false},
	}
	for _, c := range cases {
		if got := Compare(c.v, c.op, c.th); got != c.expect {
			t.Errorf("Compare(%v,%q,%v)=%v, want %v", c.v, c.op, c.th, got, c.expect)
		}
	}
}

func TestMetricValue(t *testing.T) {
	m := &model.ServerMetric{CPUPct: 1, MemPct: 2, DiskPct: 3}

	if v, ok := MetricValue(m, "cpu_pct"); !ok || v != 1 {
		t.Errorf("cpu: %v %v", v, ok)
	}
	if v, ok := MetricValue(m, "mem_pct"); !ok || v != 2 {
		t.Errorf("mem: %v %v", v, ok)
	}
	if v, ok := MetricValue(m, "disk_pct"); !ok || v != 3 {
		t.Errorf("disk: %v %v", v, ok)
	}
	if _, ok := MetricValue(m, "offline"); ok {
		t.Error("offline 不应由 MetricValue 处理")
	}
}
