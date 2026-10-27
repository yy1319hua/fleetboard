package db

import (
	"database/sql"
	"errors"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// ErrRuleNotFound 告警规则不存在。
var ErrRuleNotFound = errors.New("告警规则不存在")

// AlertRuleInput 创建/更新告警规则的入参。
type AlertRuleInput struct {
	ServerID       *int64 // nil = 全局规则
	Metric         string // cpu_pct | mem_pct | disk_pct | offline
	Operator       string // > >= < <= =
	Threshold      float64
	Severity       string // info | warn | critical
	Enabled        bool
	NotifyChannels string // 如 "inapp,pushplus"
}

const ruleColumns = `id, server_id, metric, operator, threshold, severity, enabled, notify_channels, created_at`

func scanRule(sc interface{ Scan(dest ...any) error }) (*model.AlertRule, error) {
	var (
		r       model.AlertRule
		sid     sql.NullInt64
		enabled int
	)
	if err := sc.Scan(
		&r.ID, &sid, &r.Metric, &r.Operator, &r.Threshold,
		&r.Severity, &enabled, &r.NotifyChannels, &r.CreatedAt,
	); err != nil {
		return nil, err
	}
	if sid.Valid {
		v := sid.Int64
		r.ServerID = &v
	}
	r.Enabled = enabled != 0
	return &r, nil
}

// CreateAlertRule 新建告警规则。
func CreateAlertRule(d *sql.DB, in AlertRuleInput) (*model.AlertRule, error) {
	if in.Metric == "" {
		return nil, errors.New("metric 不能为空")
	}
	if in.Operator == "" {
		in.Operator = ">"
	}
	if in.Severity == "" {
		in.Severity = "warn"
	}
	if in.NotifyChannels == "" {
		in.NotifyChannels = "inapp"
	}
	enabled := 0
	if in.Enabled {
		enabled = 1
	}

	res, err := d.Exec(
		`INSERT INTO alert_rules(server_id, metric, operator, threshold, severity, enabled, notify_channels)
		 VALUES (?,?,?,?,?,?,?)`,
		in.ServerID, in.Metric, in.Operator, in.Threshold, in.Severity, enabled, in.NotifyChannels,
	)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return GetAlertRule(d, id)
}

// GetAlertRule 按 ID 查询规则。
func GetAlertRule(d *sql.DB, id int64) (*model.AlertRule, error) {
	row := d.QueryRow(`SELECT `+ruleColumns+` FROM alert_rules WHERE id = ?`, id)
	r, err := scanRule(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrRuleNotFound
	}
	if err != nil {
		return nil, err
	}
	return r, nil
}

// ListAlertRules 返回全部规则。
func ListAlertRules(d *sql.DB) ([]model.AlertRule, error) {
	rows, err := d.Query(`SELECT ` + ruleColumns + ` FROM alert_rules ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.AlertRule{}
	for rows.Next() {
		r, err := scanRule(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// DeleteAlertRule 删除规则。
func DeleteAlertRule(d *sql.DB, id int64) error {
	res, err := d.Exec(`DELETE FROM alert_rules WHERE id = ?`, id)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrRuleNotFound
	}
	return nil
}

const eventColumns = `id, server_id, rule_id, severity, title, message, is_read, created_at`

func scanEvent(sc interface{ Scan(dest ...any) error }) (*model.AlertEvent, error) {
	var (
		e      model.AlertEvent
		sid    sql.NullInt64
		rid    sql.NullInt64
		isRead int
	)
	if err := sc.Scan(
		&e.ID, &sid, &rid, &e.Severity, &e.Title, &e.Message, &isRead, &e.CreatedAt,
	); err != nil {
		return nil, err
	}
	if sid.Valid {
		v := sid.Int64
		e.ServerID = &v
	}
	if rid.Valid {
		v := rid.Int64
		e.RuleID = &v
	}
	e.IsRead = isRead != 0
	return &e, nil
}

// InsertAlertEvent 写入一条通知中心事件。
func InsertAlertEvent(d *sql.DB, serverID, ruleID *int64, severity, title, message string) (int64, error) {
	res, err := d.Exec(
		`INSERT INTO alert_events(server_id, rule_id, severity, title, message) VALUES (?,?,?,?,?)`,
		serverID, ruleID, severity, title, message,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// ListAlertEvents 返回通知中心事件（倒序）；unreadOnly 只看未读。
func ListAlertEvents(d *sql.DB, unreadOnly bool, limit int) ([]model.AlertEvent, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}

	q := `SELECT ` + eventColumns + ` FROM alert_events`
	if unreadOnly {
		q += ` WHERE is_read = 0`
	}
	q += ` ORDER BY id DESC LIMIT ?`

	rows, err := d.Query(q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.AlertEvent{}
	for rows.Next() {
		e, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *e)
	}
	return out, rows.Err()
}

// MarkAlertRead 标记事件已读。
func MarkAlertRead(d *sql.DB, id int64) error {
	_, err := d.Exec(`UPDATE alert_events SET is_read = 1 WHERE id = ?`, id)
	return err
}
