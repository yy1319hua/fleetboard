// Package alert 负责告警规则评估与通知。
package alert

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
)

// DefaultCooldown 是未显式配置时的通知冷却。
const DefaultCooldown = 10 * time.Minute

// Engine 评估告警规则并在推送前做抑制。
//
// 抑制按 (服务器, 规则) 维护「上次通知时间」：首次命中立即报，之后冷却期内的
// 重复命中静默。没有抑制时，一台机器持续越阈值一小时会产出 120 条通知与
// 120 次**同步** HTTP 推送（sendPushPlus 10s 超时），把采集循环一起拖慢。
type Engine struct {
	mu       sync.Mutex
	cooldown time.Duration
	lastFire map[string]time.Time
	now      func() time.Time
}

// NewEngine 创建评估引擎；cooldown <= 0 时用 DefaultCooldown。
func NewEngine(cooldown time.Duration) *Engine {
	if cooldown <= 0 {
		cooldown = DefaultCooldown
	}
	return &Engine{
		cooldown: cooldown,
		lastFire: make(map[string]time.Time),
		now:      time.Now,
	}
}

// defaultEngine 供包级 Evaluate 使用（测试与一次性调用）。
var defaultEngine = NewEngine(DefaultCooldown)

// Evaluate 对某服务器的最新指标评估所有启用规则，命中则写通知事件并推送。
// 使用默认冷却的共享引擎；后台采集循环应自己 NewEngine 以便按配置设定冷却。
func Evaluate(d *sql.DB, serverID int64, m *model.ServerMetric, pushPlusToken string) (int, error) {
	return defaultEngine.Evaluate(d, serverID, m, pushPlusToken)
}

// Evaluate 评估指标类规则（cpu/mem/disk）。
func (e *Engine) Evaluate(d *sql.DB, serverID int64, m *model.ServerMetric, pushPlusToken string) (int, error) {
	return e.evaluate(d, serverID, m, pushPlusToken, false)
}

// EvaluateOffline 评估 offline 规则。离线是布尔事实，不来自指标快照：
// 采集连续失败达到阈值时由调用方触发，`MetricValue` 也就不需要（也不该）
// 为它编造一个数值。
func (e *Engine) EvaluateOffline(d *sql.DB, serverID int64, pushPlusToken string) (int, error) {
	return e.evaluate(d, serverID, nil, pushPlusToken, true)
}

// ClearOffline 在主机恢复在线时复位它的离线通知状态，
// 这样下次真的离线会立刻再报，不必等冷却走完。
func (e *Engine) ClearOffline(serverID int64) {
	prefix := fmt.Sprintf("%d:", serverID)
	e.mu.Lock()
	defer e.mu.Unlock()
	for k := range e.lastFire {
		if strings.HasPrefix(k, prefix) && strings.HasSuffix(k, ":offline") {
			delete(e.lastFire, k)
		}
	}
}

// allow 判断本次命中是否应真正通知（首次或冷却到期），并记录通知时间。
func (e *Engine) allow(serverID, ruleID int64, metric string) bool {
	key := fmt.Sprintf("%d:%d:%s", serverID, ruleID, metric)
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	if last, ok := e.lastFire[key]; ok && now.Sub(last) < e.cooldown {
		return false
	}
	e.lastFire[key] = now
	return true
}

func (e *Engine) evaluate(d *sql.DB, serverID int64, m *model.ServerMetric, pushPlusToken string, offlineOnly bool) (int, error) {
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
		isOffline := r.Metric == "offline"
		if isOffline != offlineOnly {
			continue
		}

		var val float64
		var msg string
		if isOffline {
			// 能走到这里说明该机已达失败阈值；用 1 参与比较，
			// 让 `offline = 1` / `offline > 0` 这类常见写法都能生效。
			val = 1
			msg = fmt.Sprintf("服务器 #%d 已离线：连续采集失败达到阈值", serverID)
		} else {
			v, ok := MetricValue(m, r.Metric)
			if !ok {
				continue
			}
			val = v
			msg = fmt.Sprintf("服务器 #%d 当前 %s = %.2f", serverID, r.Metric, val)
		}
		if !Compare(val, r.Operator, r.Threshold) {
			continue
		}
		if !e.allow(serverID, r.ID, r.Metric) {
			continue // 冷却中：不重复入库、不重复推送
		}

		title := fmt.Sprintf("%s：%s %s %.1f", r.Severity, r.Metric, r.Operator, r.Threshold)
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
