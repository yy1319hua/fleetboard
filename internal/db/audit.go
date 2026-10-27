package db

import (
	"database/sql"

	"github.com/yy1319hua/fleetboard/internal/model"
)

// InsertAudit 写入一条操作审计。
func InsertAudit(d *sql.DB, userID int64, serverID *int64, action, detail, result string) error {
	_, err := d.Exec(
		`INSERT INTO operation_log(user_id, server_id, action, detail, result) VALUES (?,?,?,?,?)`,
		userID, serverID, action, detail, result,
	)
	return err
}

// ListAudit 按时间倒序返回最近 limit 条审计；limit 默认 100，上限 500。
func ListAudit(d *sql.DB, limit int) ([]model.OperationLog, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}

	rows, err := d.Query(
		`SELECT id, user_id, server_id, action, detail, result, created_at
		 FROM operation_log ORDER BY id DESC LIMIT ?`, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.OperationLog{}
	for rows.Next() {
		var (
			l   model.OperationLog
			sid sql.NullInt64
		)
		if err := rows.Scan(&l.ID, &l.UserID, &sid, &l.Action, &l.Detail, &l.Result, &l.CreatedAt); err != nil {
			return nil, err
		}
		if sid.Valid {
			v := sid.Int64
			l.ServerID = &v
		}
		out = append(out, l)
	}
	return out, rows.Err()
}
