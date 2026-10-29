package db

import (
	crand "crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"

	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/model"
)

// ErrUserNotFound 表示按用户名查询不到用户。
var ErrUserNotFound = errors.New("用户不存在")

// ErrUsernameTaken 表示目标用户名已被占用。
var ErrUsernameTaken = errors.New("用户名已被占用")

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

// UpdateUsername 修改用户名。返回受影响行数为 0 时说明用户不存在。
//
// 重名判定以 users.username 的 UNIQUE 约束为准：调用方可以先查一次以给出
// 更友好的提示，但预查与写入之间存在并发窗口，最终必须由这里的约束兜底。
// 错误串匹配而非错误码，是为了不绑死 modernc 驱动的内部 API；串形如
// "constraint failed: UNIQUE constraint failed: users.username (2067)"。
func UpdateUsername(d *sql.DB, id int64, username string) error {
	res, err := d.Exec(`UPDATE users SET username = ? WHERE id = ?`, username, id)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			return ErrUsernameTaken
		}
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrUserNotFound
	}
	return nil
}

// UsernameExistsCI 判断用户名是否已被他人占用（大小写不敏感）。
//
// SQLite 的 UNIQUE 是二进制比较，所以 `Admin` 与 `admin` 在库层面可以并存；
// 但登录按名精确匹配、界面上两者看起来一样，用户会以为是同一个账号。
// 因此重名判定在应用层做大小写不敏感的比较，excludeID 用于排除自己。
func UsernameExistsCI(d *sql.DB, username string, excludeID int64) (bool, error) {
	var n int
	err := d.QueryRow(
		`SELECT COUNT(1) FROM users WHERE lower(username) = lower(?) AND id <> ?`,
		username, excludeID,
	).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// BumpTokenVer 仅自增 token_ver（注销其他会话用），不动密码。返回新版本号。
func BumpTokenVer(d *sql.DB, id int64) (int64, error) {
	return bumpVer(d, id, "")
}

// EnsureBootstrapAdmin 首启自举兜底（M8.1a）：users 表为空时，
// BOOTSTRAP_* 齐全则用之；缺任一则生成随机密码（用户名固定 admin）。
// 返回 (创建的用户名, 密码, 是否随机生成, 是否新建)。
func EnsureBootstrapAdmin(d *sql.DB, bootstrapUser, bootstrapPass string) (string, string, bool, bool, error) {
	var n int
	if err := d.QueryRow(`SELECT COUNT(1) FROM users`).Scan(&n); err != nil {
		return "", "", false, false, err
	}
	if n > 0 {
		return "", "", false, false, nil
	}
	user, pass := bootstrapUser, bootstrapPass
	if user == "" {
		user = "admin"
	}
	generated := false
	if pass == "" {
		b := make([]byte, 9)
		if _, err := crand.Read(b); err != nil {
			return "", "", false, false, err
		}
		pass = hex.EncodeToString(b)
		generated = true
	}
	hash, err := auth.HashPassword(pass)
	if err != nil {
		return "", "", false, false, err
	}
	if _, err := d.Exec(`INSERT INTO users(username, password_hash) VALUES (?, ?)`, user, hash); err != nil {
		return "", "", false, false, err
	}
	return user, pass, generated, true, nil
}
