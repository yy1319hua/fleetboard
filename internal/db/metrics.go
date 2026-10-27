package db

import "database/sql"

// InsertMetric 写入一条指标采样。
func InsertMetric(d *sql.DB, serverID int64, cpu, mem, disk, load1 float64) error {
	_, err := d.Exec(
		`INSERT INTO server_metrics(server_id, cpu_pct, mem_pct, disk_pct, load1) VALUES (?,?,?,?,?)`,
		serverID, cpu, mem, disk, load1,
	)
	return err
}
