// Package alert 负责告警规则评估与通知。
package alert

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
)

// Evaluate 对某服务器的最新指标评估所有启用规则，命中则写通知事件并推送，返回命中条数。
func Evaluate(d *sql.DB, serverID int64, m *model.ServerMetric, pushPlusToken string) (int, error) {
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

		// PushPlus：失败仅记日志，不影响主流程（不阻断采集与入库）
		if pushPlusToken != "" && strings.Contains(r.NotifyChannels, "pushplus") {
			if err := sendPushPlus(pushPlusToken, title, msg); err != nil {
				log.Printf("PushPlus 推送失败（不阻断）: %v", err)
			}
		}
	}
	return hits, nil
}

// SendPushPlus 对外暴露的测试推送入口（M8.1c 设置页「测试」按钮）。
func SendPushPlus(token, title, content string) error {
	return sendPushPlus(token, title, content)
}

// sendPushPlus 调用 PushPlus Webhook。
func sendPushPlus(token, title, content string) error {
	form := url.Values{}
	form.Set("token", token)
	form.Set("title", title)
	form.Set("content", content)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.PostForm("https://www.pushplus.plus/send", form)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode >= 300 {
		return fmt.Errorf("pushplus 返回状态 %d", resp.StatusCode)
	}
	return nil
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
