// Package alert 负责告警规则评估与通知。
package alert

import (
	"database/sql"
	"fmt"

	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
)

// Evaluate 对某服务器的最新指标评估所有启用规则，命中则写通知事件，返回命中条数。
func Evaluate(d *sql.DB, serverID int64, m *model.ServerMetric) (int, error) {
	rules, err := db.ListAlertRules(d)
	if err != nil {
		return 0, err
	}

	hits := 0
	for _, r := range rules {
		if !r.Enabled {
			continue
		}
		if r.ServerID != nil && *r.ServerID != serverID {
			continue
		}

		val, ok := MetricValue(m, r.Metric)
		if !ok {
			continue
		}
		if !Compare(val, r.Operator, r.Threshold) {
			continue
		}

		title := fmt.Sprintf("%s：%s %s %.1f", r.Severity, r.Metric, r.Operator, r.Threshold)
		msg := fmt.Sprintf("服务器 #%d 当前 %s = %.2f", serverID, r.Metric, val)

		sid, rid := serverID, r.ID
		if _, err := db.InsertAlertEvent(d, &sid, &rid, r.Severity, title, msg); err != nil {
			return hits, err
		}
		hits++
	}
	return hits, nil
}

// MetricValue 取指标数值；offline 由连接状态单独判断，不在此处理。
func MetricValue(m *model.ServerMetric, metric string) (float64, bool) {
	switch metric {
	case "cpu_pct":
		return m.CPUPct, true
	case "mem_pct":
		return m.MemPct, true
	case "disk_pct":
		return m.DiskPct, true
	default:
		return 0, false
	}
}

// Compare 按操作符比较。
func Compare(v float64, op string, th float64) bool {
	switch op {
	case ">":
		return v > th
	case ">=":
		return v >= th
	case "<":
		return v < th
	case "<=":
		return v <= th
	case "=":
		return v == th
	default:
		return false
	}
}
