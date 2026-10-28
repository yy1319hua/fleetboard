package db

import (
	"database/sql"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// LatestMetricsPerServer 用窗口函数一次性取每台服务器的最新一条采样，规避 N+1。
// 返回 map[serverID]*ServerMetric；无数据的服务器不出现在 map 中（某机缺失不整包失败）。
func LatestMetricsPerServer(d *sql.DB) (map[int64]*model.ServerMetric, error) {
	rows, err := d.Query(`
		SELECT ` + metricColumns + `
		FROM (
			SELECT ` + metricColumns + `,
				ROW_NUMBER() OVER (PARTITION BY server_id ORDER BY ts DESC) AS rn
			FROM server_metrics
		) t
		WHERE rn = 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make(map[int64]*model.ServerMetric)
	for rows.Next() {
		m, err := scanMetric(rows)
		if err != nil {
			return nil, err
		}
		out[m.ServerID] = m
	}
	return out, rows.Err()
}

// CountUnreadAlerts 返回通知中心未读事件总数。
func CountUnreadAlerts(d *sql.DB) (int, error) {
	var n int
	if err := d.QueryRow(`SELECT COUNT(1) FROM alert_events WHERE is_read = 0`).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}
