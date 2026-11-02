package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// UpsertFacts 写入或覆盖一台主机的静态配置（一服务器一行，按小时刷新）。
func UpsertFacts(d *sql.DB, f *model.ServerFacts) error {
	disks, err := json.Marshal(f.Disks)
	if err != nil {
		return fmt.Errorf("序列化磁盘列表: %w", err)
	}

	_, err = d.Exec(`
INSERT INTO server_facts(
    server_id, cpu_model, cpu_cores, mem_total_kb, swap_total_kb,
    os_name, kernel, arch, hostname, uptime_sec, virt, disks_json, collected_at
) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
ON CONFLICT(server_id) DO UPDATE SET
    cpu_model     = excluded.cpu_model,
    cpu_cores     = excluded.cpu_cores,
    mem_total_kb  = excluded.mem_total_kb,
    swap_total_kb = excluded.swap_total_kb,
    os_name       = excluded.os_name,
    kernel        = excluded.kernel,
    arch          = excluded.arch,
    hostname      = excluded.hostname,
    uptime_sec    = excluded.uptime_sec,
    virt          = excluded.virt,
    disks_json    = excluded.disks_json,
    collected_at  = CURRENT_TIMESTAMP`,
		f.ServerID, f.CPUModel, f.CPUCores, f.MemTotalKB, f.SwapTotalKB,
		f.OSName, f.Kernel, f.Arch, f.Hostname, f.UptimeSec, f.Virt, string(disks),
	)
	return err
}

const factsColumns = `server_id, cpu_model, cpu_cores, mem_total_kb, swap_total_kb,
    os_name, kernel, arch, hostname, uptime_sec, virt, disks_json, collected_at`

// GetFacts 返回某服务器的静态配置；从未采集过返回 (nil, nil)，由调用方决定文案。
func GetFacts(d *sql.DB, serverID int64) (*model.ServerFacts, error) {
	var (
		f         model.ServerFacts
		disksJSON string
	)
	err := d.QueryRow(`SELECT `+factsColumns+` FROM server_facts WHERE server_id = ?`, serverID).Scan(
		&f.ServerID, &f.CPUModel, &f.CPUCores, &f.MemTotalKB, &f.SwapTotalKB,
		&f.OSName, &f.Kernel, &f.Arch, &f.Hostname, &f.UptimeSec, &f.Virt,
		&disksJSON, &f.CollectedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	// 磁盘列表是 JSON 字符串列：单条数据坏掉时退化为空列表，
	// 不让整张「系统配置」卡因为一个字段解析失败而打不开。
	f.Disks = []model.DiskUsage{}
	if disksJSON != "" {
		var disks []model.DiskUsage
		if err := json.Unmarshal([]byte(disksJSON), &disks); err == nil && disks != nil {
			f.Disks = disks
		}
	}
	return &f, nil
}
