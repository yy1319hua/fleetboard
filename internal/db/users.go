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
		`SELECT id, username, password_hash, created_at FROM users WHERE username = ?`, username,
	).Scan(&u.ID, &u.Username, &u.PasswordHash, &u.CreatedAt)
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
