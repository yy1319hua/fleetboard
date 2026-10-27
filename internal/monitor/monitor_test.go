package monitor

import "testing"

func TestParseMetricsLine(t *testing.T) {
	s, err := ParseMetricsLine("12.30 45.60 78.90 0.42")
	if err != nil {
		t.Fatalf("ParseMetricsLine: %v", err)
	}
	if s.CPUPct != 12.30 || s.MemPct != 45.60 || s.DiskPct != 78.90 || s.Load1 != 0.42 {
		t.Errorf("解析错误: %+v", s)
	}
}

func TestParseMetricsLineErrors(t *testing.T) {
	if _, err := ParseMetricsLine("1 2 3"); err == nil {
		t.Error("字段不足应报错")
	}
	if _, err := ParseMetricsLine("a b c d"); err == nil {
		t.Error("非数字应报错")
	}
	if _, err := ParseMetricsLine(""); err == nil {
		t.Error("空串应报错")
	}
}
