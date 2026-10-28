package db

import (
	"database/sql"
	"errors"

	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/model"
)

// ErrUserNotFound 表示按用户名查询不到用户。
var ErrUserNotFound = errors.New("用户不存在")

// EnsureAdmin 若 users 表为空且提供了 bootstrap 账号，则创建管理员，返回是否新建。
// 已有用户时直接跳过（幂等），不会覆盖既有账户。
func EnsureAdmin(d *sql.DB, username, password string) (bool, error) {
	if username == "" || password == "" {
		return false, nil
	}

	var n int
	if err := d.QueryRow(`SELECT COUNT(1) FROM users`).Scan(&n); err != nil {
		return false, err
	}
	if n > 0 {
		return false, nil
	}

	hash, err := auth.HashPassword(password)
	if err != nil {
		return false, err
	}
	if _, err := d.Exec(`INSERT INTO users(username, password_hash) VALUES (?, ?)`, username, hash); err != nil {
		return false, err
	}
	return true, nil
}

// GetUserByUsername 按用户名查询用户；不存在返回 ErrUserNotFound。
func GetUserByUsername(d *sql.DB, username string) (*model.User, error) {
	var u model.User
	err := d.QueryRow(
		`SELECT id, username, password_hash, token_ver, created_at FROM users WHERE username = ?`, username,
	).Scan(&u.ID, &u.Username, &u.PasswordHash, &u.TokenVer, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// CountUsers 返回用户总数。
func CountUsers(d *sql.DB) (int, error) {
	var n int
	err := d.QueryRow(`SELECT COUNT(1) FROM users`).Scan(&n)
	return n, err
}

// GetUserByID 按 ID 查询用户；不存在返回 ErrUserNotFound。
func GetUserByID(d *sql.DB, id int64) (*model.User, error) {
	var usr model.User
	err := d.QueryRow(
		`SELECT id, username, password_hash, token_ver, created_at FROM users WHERE id = ?`, id,
	).Scan(&usr.ID, &usr.Username, &usr.PasswordHash, &usr.TokenVer, &usr.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, err
	}
	return &usr, nil
}

// bumpVer 在事务内自增 token_ver；passwordHash 非空则同事务更新密码。返回新版本号。
func bumpVer(d *sql.DB, id int64, passwordHash string) (int64, error) {
	tx, err := d.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	if passwordHash != "" {
		if _, err := tx.Exec(`UPDATE users SET password_hash = ?, token_ver = token_ver + 1 WHERE id = ?`, passwordHash, id); err != nil {
			return 0, err
		}
	} else {
		if _, err := tx.Exec(`UPDATE users SET token_ver = token_ver + 1 WHERE id = ?`, id); err != nil {
			return 0, err
		}
	}
	var ver int64
	if err := tx.QueryRow(`SELECT token_ver FROM users WHERE id = ?`, id).Scan(&ver); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return ver, nil
}

// GetTokenVer 查询用户当前 token 版本号；不存在返回 ErrUserNotFound。
func GetTokenVer(d *sql.DB, id int64) (int64, error) {
	usr, err := GetUserByID(d, id)
	if err != nil {
		return 0, err
	}
	return usr.TokenVer, nil
}

// UpdatePasswordAndBumpVer 更新密码并自增 token_ver（同事务），返回新版本号。
func UpdatePasswordAndBumpVer(d *sql.DB, id int64, passwordHash string) (int64, error) {
	return bumpVer(d, id, passwordHash)
}

// BumpTokenVer 仅自增 token_ver（注销其他会话用），不动密码。返回新版本号。
func BumpTokenVer(d *sql.DB, id int64) (int64, error) {
	return bumpVer(d, id, "")
}
