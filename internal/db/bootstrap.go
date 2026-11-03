package db

import (
	"database/sql"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// LatestMetricsPerServer 用窗口函数一次性取每台服务器的最新一条采样，规避 N+1。
// 返回 map[serverID]*ServerMetric；无数据的服务器不出现在 map 中（某机缺失不整包失败）。
func LatestMetricsPerServer(d *sql.DB) (map[int64]*model.ServerMetric, error) {
	// 以 servers 驱动、每台按 (server_id, ts) 索引倒序取 1 条。
	// 原来的 ROW_NUMBER() 窗口要把整张 server_metrics 排序一遍：30 天数据后
	// 每次首屏都要扫上百万行，而 SetMaxOpenConns(1) 会让这期间所有请求排队。
	const cols = `m.id, m.server_id, m.ts, m.cpu_pct, m.mem_pct, m.disk_pct, m.load1, m.net_in_kbps, m.net_out_kbps`
	rows, err := d.Query(`
		SELECT ` + cols + `
		FROM servers s
		JOIN server_metrics m ON m.id = (
			SELECT id FROM server_metrics
			WHERE server_id = s.id
			ORDER BY ts DESC, id DESC
			LIMIT 1
		)`)
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
