package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// UpsertFacts 写入或覆盖一台主机的静态配置（一服务器一行）。
//
// 注意：这里**不碰** has_docker / has_sftp / probed_at 三列。
// 配置采集（首次采集、失败重试）与能力探测是两条独立的写入路径——
// 如果配置刷新顺手把能力列覆盖成零值，装没装 Docker 的判断会被抹掉，
// 容器 Tab 就会莫名其妙地消失。能力列只由 UpdateCapabilities 改。
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

// UpdateCapabilities 写入体检测出的能力（-1 未检测 / 0 不支持 / 1 支持）。
//
// 前提：server_facts 里已有该机的行（probeServer 先调 UpsertFacts）。
// 影响 0 行说明配置没采到，此时能力也无处可存，直接放过——下次体检会再来一遍。
func UpdateCapabilities(d *sql.DB, serverID int64, hasDocker, hasSFTP int) error {
	_, err := d.Exec(`
UPDATE server_facts
   SET has_docker = ?, has_sftp = ?, probed_at = CURRENT_TIMESTAMP
 WHERE server_id = ?`, hasDocker, hasSFTP, serverID)
	return err
}

// ListFactsServerIDs 返回已有配置记录的服务器 id。
//
// 采集循环用它做启动预热：进程重启后内存里的「已采过」状态是空的，
// 如果不预热，所有机器会各被重采一次——对限制并发的主机是一笔无谓开销。
func ListFactsServerIDs(d *sql.DB) ([]int64, error) {
	rows, err := d.Query(`SELECT server_id FROM server_facts`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

const factsColumns = `server_id, cpu_model, cpu_cores, mem_total_kb, swap_total_kb,
    os_name, kernel, arch, hostname, uptime_sec, virt, disks_json,
    has_docker, has_sftp, probed_at, collected_at`

// GetFacts 返回某服务器的静态配置；从未采集过返回 (nil, nil)，由调用方决定文案。
func GetFacts(d *sql.DB, serverID int64) (*model.ServerFacts, error) {
	var (
		f         model.ServerFacts
		disksJSON string
		probedAt  sql.NullTime
	)
	err := d.QueryRow(`SELECT `+factsColumns+` FROM server_facts WHERE server_id = ?`, serverID).Scan(
		&f.ServerID, &f.CPUModel, &f.CPUCores, &f.MemTotalKB, &f.SwapTotalKB,
		&f.OSName, &f.Kernel, &f.Arch, &f.Hostname, &f.UptimeSec, &f.Virt,
		&disksJSON, &f.HasDocker, &f.HasSFTP, &probedAt, &f.CollectedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if probedAt.Valid {
		t := probedAt.Time
		f.ProbedAt = &t
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
