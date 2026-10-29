package db

import (
	"database/sql"
	"errors"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// 升级记录状态取值。与 internal/upgrade.Snapshot.State 的终态集合保持一致，
// 便于「状态文件 → 历史表」直接落库，不需要额外的映射表。
const (
	UpgradeInProgress = "in_progress"
	UpgradeDone       = "done"
	UpgradeFailed     = "failed"
	UpgradeRolledBack = "rolled_back"
	UpgradeInterrupt  = "interrupted"
)

const upgradeColumns = `id, from_version, to_version, status, started_at, finished_at,
	duration_ms, error_code, triggered_by, log_path`

func scanUpgrade(sc interface{ Scan(dest ...any) error }) (*model.UpgradeRecord, error) {
	var (
		r        model.UpgradeRecord
		finished sql.NullTime
		by       sql.NullInt64
	)
	if err := sc.Scan(
		&r.ID, &r.FromVersion, &r.ToVersion, &r.Status, &r.StartedAt, &finished,
		&r.DurationMs, &r.ErrorCode, &by, &r.LogPath,
	); err != nil {
		return nil, err
	}
	if finished.Valid {
		t := finished.Time
		r.FinishedAt = &t
	}
	if by.Valid {
		v := by.Int64
		r.TriggeredBy = &v
	}
	return &r, nil
}

// InsertUpgradeStart 记录一次升级启动，返回记录 ID。
//
// 先落库再真正触发升级：即便编排层随后失败，审计链条上也留下了「谁在何时点了升级」。
// triggeredBy <= 0 时写 NULL（系统/对账路径没有触发者）。
func InsertUpgradeStart(d *sql.DB, from, to string, triggeredBy int64, logPath string) (int64, error) {
	var by any
	if triggeredBy > 0 {
		by = triggeredBy
	}
	res, err := d.Exec(
		`INSERT INTO system_upgrades(from_version, to_version, status, triggered_by, log_path)
		 VALUES (?,?,?,?,?)`,
		from, to, UpgradeInProgress, by, logPath,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// FinishUpgrade 把记录推进到终态并记下耗时与错误码。
func FinishUpgrade(d *sql.DB, id int64, status, errorCode string, durationMs int64) error {
	if durationMs < 0 {
		durationMs = 0
	}
	_, err := d.Exec(
		`UPDATE system_upgrades
		    SET status = ?, error_code = ?, duration_ms = ?, finished_at = CURRENT_TIMESTAMP
		  WHERE id = ?`,
		status, errorCode, durationMs, id,
	)
	return err
}

// SetUpgradeLogPath 回填日志路径：日志文件由编排层在 Start 时生成，
// 落库那一刻还拿不到路径，故启动记录与路径分两步写。
func SetUpgradeLogPath(d *sql.DB, id int64, logPath string) error {
	_, err := d.Exec(`UPDATE system_upgrades SET log_path = ? WHERE id = ?`, logPath, id)
	return err
}

// LatestUpgrades 返回最近 limit 条升级记录（started_at DESC, id DESC）。
func LatestUpgrades(d *sql.DB, limit int) ([]model.UpgradeRecord, error) {
	if limit <= 0 {
		limit = 10
	}
	if limit > 200 {
		limit = 200
	}
	rows, err := d.Query(
		`SELECT `+upgradeColumns+` FROM system_upgrades
		  ORDER BY started_at DESC, id DESC LIMIT ?`, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.UpgradeRecord{}
	for rows.Next() {
		r, err := scanUpgrade(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *r)
	}
	return out, rows.Err()
}

// ListUpgrades 分页返回升级记录与总数（total 供前端算页数）。
func ListUpgrades(d *sql.DB, limit, offset int) ([]model.UpgradeRecord, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 200 {
		limit = 200
	}
	if offset < 0 {
		offset = 0
	}

	var total int
	if err := d.QueryRow(`SELECT COUNT(1) FROM system_upgrades`).Scan(&total); err != nil {
		return nil, 0, err
	}

	rows, err := d.Query(
		`SELECT `+upgradeColumns+` FROM system_upgrades
		  ORDER BY started_at DESC, id DESC LIMIT ? OFFSET ?`, limit, offset,
	)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	out := []model.UpgradeRecord{}
	for rows.Next() {
		r, err := scanUpgrade(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *r)
	}
	return out, total, rows.Err()
}

// LatestInProgressUpgrade 返回最近一条「进行中」记录；没有则返回 (nil, nil)。
// 升级是单例资源，最多只应存在一条在途记录。
func LatestInProgressUpgrade(d *sql.DB) (*model.UpgradeRecord, error) {
	row := d.QueryRow(
		`SELECT ` + upgradeColumns + ` FROM system_upgrades
		  WHERE status = 'in_progress' ORDER BY started_at DESC, id DESC LIMIT 1`,
	)
	r, err := scanUpgrade(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return r, nil
}
