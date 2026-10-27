package db

import (
	"database/sql"
	"errors"
	"time"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// InsertMetric 写入一条指标采样。
func InsertMetric(d *sql.DB, serverID int64, cpu, mem, disk, load1 float64) error {
	_, err := d.Exec(
		`INSERT INTO server_metrics(server_id, cpu_pct, mem_pct, disk_pct, load1) VALUES (?,?,?,?,?)`,
		serverID, cpu, mem, disk, load1,
	)
	return err
}

const metricColumns = `id, server_id, ts, cpu_pct, mem_pct, disk_pct, load1, net_in_kbps, net_out_kbps`

func scanMetric(sc interface{ Scan(dest ...any) error }) (*model.ServerMetric, error) {
	var m model.ServerMetric
	if err := sc.Scan(
		&m.ID, &m.ServerID, &m.TS, &m.CPUPct, &m.MemPct, &m.DiskPct, &m.Load1, &m.NetIn, &m.NetOut,
	); err != nil {
		return nil, err
	}
	return &m, nil
}

// QueryMetrics 返回某服务器 since 之后的采样，按时间升序。
// 说明：表内 ts 由 CURRENT_TIMESTAMP 写入（UTC，无时区后缀），此处统一按 UTC 字符串比较。
func QueryMetrics(d *sql.DB, serverID int64, since time.Time) ([]model.ServerMetric, error) {
	rows, err := d.Query(
		`SELECT `+metricColumns+` FROM server_metrics WHERE server_id = ? AND ts >= ? ORDER BY ts ASC`,
		serverID, since.UTC().Format("2006-01-02 15:04:05"),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.ServerMetric{}
	for rows.Next() {
		m, err := scanMetric(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *m)
	}
	return out, rows.Err()
}

// LatestMetric 返回最新一条采样；无数据返回 (nil, nil)。
func LatestMetric(d *sql.DB, serverID int64) (*model.ServerMetric, error) {
	row := d.QueryRow(
		`SELECT `+metricColumns+` FROM server_metrics WHERE server_id = ? ORDER BY ts DESC LIMIT 1`, serverID,
	)
	m, err := scanMetric(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// PruneMetrics 删除早于 cutoff 的采样，返回删除行数。
func PruneMetrics(d *sql.DB, cutoff time.Time) (int64, error) {
	res, err := d.Exec(`DELETE FROM server_metrics WHERE ts < ?`, cutoff.UTC().Format("2006-01-02 15:04:05"))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
