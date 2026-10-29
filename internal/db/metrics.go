package db

import (
	"database/sql"
	"errors"
	"fmt"
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

// scanDownsampledMetric 专供降采样结果使用。
//
// 不能复用 scanMetric：`MIN(ts)` 是聚合表达式，驱动已丢失该列的 DATETIME
// 声明类型，会把值当 string 返回，直接扫进 time.Time 会报
// "unsupported Scan, storing driver.Value type string into type *time.Time"。
func scanDownsampledMetric(sc interface{ Scan(dest ...any) error }) (*model.ServerMetric, error) {
	var m model.ServerMetric
	var ts string
	if err := sc.Scan(
		&m.ID, &m.ServerID, &ts, &m.CPUPct, &m.MemPct, &m.DiskPct, &m.Load1, &m.NetIn, &m.NetOut,
	); err != nil {
		return nil, err
	}
	t, err := time.Parse("2006-01-02 15:04:05", ts)
	if err != nil {
		return nil, fmt.Errorf("解析聚合时间戳 %q: %w", ts, err)
	}
	m.TS = t
	return &m, nil
}

// QueryMetricsDownsampled 返回按 stepSec 秒分桶聚合后的采样，按时间升序。
//
// 为什么必须在服务端分桶：7d × 30s ≈ 2 万行/指标，原样 JSON 出去是 MB 级，
// 手机端会先卡在解析上。分组键用「(样本 epoch - since 的 epoch) / step」，
// 而不是「epoch / step」——用绝对时间分桶会让首尾桶残缺，同一份数据在不同
// 请求时刻切出的桶边界还会漂移，曲线看起来会抖。
//
// 聚合用 AVG 而不是 SUM/COUNT：离线期间缺采样时不该补零，AVG 只对实有样本求均值。
// MIN(id)/MIN(ts) 用于给这个桶一个稳定的代表值（扫描到的第一条样本时间）。
func QueryMetricsDownsampled(d *sql.DB, serverID int64, since time.Time, stepSec int) ([]model.ServerMetric, error) {
	if stepSec < 1 {
		stepSec = 1
	}
	sinceStr := since.UTC().Format("2006-01-02 15:04:05")
	rows, err := d.Query(
		`SELECT MIN(id), server_id, MIN(ts),
		        AVG(cpu_pct), AVG(mem_pct), AVG(disk_pct), AVG(load1),
		        AVG(COALESCE(net_in_kbps, 0)), AVG(COALESCE(net_out_kbps, 0))
		   FROM server_metrics
		  WHERE server_id = ? AND ts >= ?
		  GROUP BY (CAST(strftime('%s', ts) AS INTEGER) - CAST(strftime('%s', ?) AS INTEGER)) / ?
		  ORDER BY MIN(ts) ASC`,
		serverID, sinceStr, sinceStr, stepSec,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.ServerMetric{}
	for rows.Next() {
		m, err := scanDownsampledMetric(rows)
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
