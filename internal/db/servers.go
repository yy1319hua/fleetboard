package db

import (
	"database/sql"
	"errors"
	"fmt"

	"github.com/yy1319hua/fleetboard/internal/crypto"
	"github.com/yy1319hua/fleetboard/internal/model"
)

// ErrServerNotFound 表示服务器不存在。
var ErrServerNotFound = errors.New("服务器不存在")

// CreateServerInput 注册服务器所需字段（凭据为明文，落库前加密）。
type CreateServerInput struct {
	Name       string
	Host       string
	Port       int
	SSHUser    string
	AuthMethod string // password | key
	Password   string
	PrivateKey string
	KeyPass    string
	Tags       string
}

// DecryptedCredential 是解密后的凭据，仅用于建立 SSH 连接，调用方即用即弃。
type DecryptedCredential struct {
	AuthMethod string
	Password   string
	PrivateKey string
	KeyPass    string
}

// CreateServer 创建服务器并加密存储其 SSH 凭据（masterKey 来自环境变量 KEY）。
func CreateServer(d *sql.DB, masterKey string, in CreateServerInput) (*model.Server, error) {
	if in.Name == "" || in.Host == "" {
		return nil, errors.New("名称与主机地址不能为空")
	}
	if in.Port == 0 {
		in.Port = 22
	}
	if in.SSHUser == "" {
		in.SSHUser = "root"
	}
	if in.AuthMethod == "" {
		in.AuthMethod = "key"
	}

	passEnc, err := encryptOptional(masterKey, in.Password)
	if err != nil {
		return nil, err
	}
	keyEnc, err := encryptOptional(masterKey, in.PrivateKey)
	if err != nil {
		return nil, err
	}
	keyPassEnc, err := encryptOptional(masterKey, in.KeyPass)
	if err != nil {
		return nil, err
	}

	tx, err := d.Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(
		`INSERT INTO servers(name, host, port, ssh_user, auth_method, tags) VALUES (?,?,?,?,?,?)`,
		in.Name, in.Host, in.Port, in.SSHUser, in.AuthMethod, in.Tags,
	)
	if err != nil {
		return nil, fmt.Errorf("插入服务器: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}

	if _, err := tx.Exec(
		`INSERT INTO ssh_credentials(server_id, auth_method, password_enc, key_enc, key_pass_enc) VALUES (?,?,?,?,?)`,
		id, in.AuthMethod, passEnc, keyEnc, keyPassEnc,
	); err != nil {
		return nil, fmt.Errorf("插入凭据: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return GetServer(d, id)
}

// UpdateServerInput 是更新服务器的字段集合。
//
// 凭据语义（M11.2，用户明令「留空=不修改」）：
//   - Password / PrivateKey / KeyPass 留空 → 沿用库中原值，改端口不必重贴私钥；
//   - AuthMethod 留空 → 沿用原认证方式；
//   - 切换到某一认证方式时，该方式的凭据必须能从请求或原记录里取到，否则报错。
//     切换后另一方式的凭据一律清空，避免库里留着两套互相矛盾的凭据。
type UpdateServerInput struct {
	Name       string
	Host       string
	Port       int
	SSHUser    string
	AuthMethod string // password | key；空=不改
	Password   string
	PrivateKey string
	KeyPass    string
	Tags       string
}

// UpdateServer 更新服务器元信息与凭据（凭据重新加密后落库）。
func UpdateServer(d *sql.DB, masterKey string, id int64, in UpdateServerInput) (*model.Server, error) {
	if in.Name == "" || in.Host == "" {
		return nil, errors.New("名称与主机地址不能为空")
	}
	if in.Port != 0 && (in.Port < 1 || in.Port > 65535) {
		return nil, errors.New("端口需在 1–65535 之间")
	}

	cur, err := GetDecryptedCredential(d, masterKey, id)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrServerNotFound
	}
	if err != nil {
		return nil, err
	}

	if in.Port == 0 {
		in.Port = 22
	}
	if in.SSHUser == "" {
		in.SSHUser = "root"
	}
	auth := in.AuthMethod
	if auth == "" {
		auth = cur.AuthMethod
	}
	if auth != "key" && auth != "password" {
		return nil, fmt.Errorf("未知认证方式: %q", auth)
	}

	pass, key, keyPass := in.Password, in.PrivateKey, in.KeyPass
	if auth == "password" {
		if pass == "" {
			pass = cur.Password
		}
		if pass == "" {
			return nil, errors.New("认证方式为密码时密码不能为空")
		}
		key, keyPass = "", "" // 切换后清掉私钥，避免两套凭据并存
	} else {
		if key == "" {
			key = cur.PrivateKey
			if keyPass == "" {
				keyPass = cur.KeyPass
			}
		}
		if key == "" {
			return nil, errors.New("认证方式为私钥时私钥不能为空")
		}
		pass = "" // 切换后清掉密码
	}

	passEnc, err := encryptOptional(masterKey, pass)
	if err != nil {
		return nil, err
	}
	keyEnc, err := encryptOptional(masterKey, key)
	if err != nil {
		return nil, err
	}
	keyPassEnc, err := encryptOptional(masterKey, keyPass)
	if err != nil {
		return nil, err
	}

	tx, err := d.Begin()
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(
		`UPDATE servers SET name = ?, host = ?, port = ?, ssh_user = ?, auth_method = ?, tags = ? WHERE id = ?`,
		in.Name, in.Host, in.Port, in.SSHUser, auth, in.Tags, id,
	)
	if err != nil {
		return nil, fmt.Errorf("更新服务器: %w", err)
	}
	if n, err := res.RowsAffected(); err == nil && n == 0 {
		return nil, ErrServerNotFound
	}

	// 凭据行理论上必然存在（创建时同事务写入）；用 upsert 兜住历史脏数据。
	if _, err := tx.Exec(
		`INSERT INTO ssh_credentials(server_id, auth_method, password_enc, key_enc, key_pass_enc)
		 VALUES (?,?,?,?,?)
		 ON CONFLICT(server_id) DO UPDATE SET
		   auth_method = excluded.auth_method,
		   password_enc = excluded.password_enc,
		   key_enc = excluded.key_enc,
		   key_pass_enc = excluded.key_pass_enc`,
		id, auth, passEnc, keyEnc, keyPassEnc,
	); err != nil {
		return nil, fmt.Errorf("更新凭据: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return GetServer(d, id)
}

// ListServers 返回全部服务器（不含凭据）。
func ListServers(d *sql.DB) ([]model.Server, error) {
	rows, err := d.Query(
		`SELECT id, name, host, port, ssh_user, auth_method, connection_status, last_heartbeat, tags, created_at
		 FROM servers ORDER BY id`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.Server{}
	for rows.Next() {
		s, err := scanServer(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

// GetServer 按 ID 查询服务器；不存在返回 ErrServerNotFound。
func GetServer(d *sql.DB, id int64) (*model.Server, error) {
	row := d.QueryRow(
		`SELECT id, name, host, port, ssh_user, auth_method, connection_status, last_heartbeat, tags, created_at
		 FROM servers WHERE id = ?`, id,
	)
	s, err := scanServer(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrServerNotFound
	}
	if err != nil {
		return nil, err
	}
	return s, nil
}

// DeleteServer 删除服务器（ssh_credentials 由外键级联删除）。
func DeleteServer(d *sql.DB, id int64) error {
	res, err := d.Exec(`DELETE FROM servers WHERE id = ?`, id)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrServerNotFound
	}
	return nil
}

// UpdateServerStatus 更新连接状态与最后心跳时间。
func UpdateServerStatus(d *sql.DB, id int64, status string) error {
	res, err := d.Exec(
		`UPDATE servers SET connection_status = ?, last_heartbeat = CURRENT_TIMESTAMP WHERE id = ?`,
		status, id,
	)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrServerNotFound
	}
	return nil
}

// MarkServerUnknown 仅把连接状态置 unknown，**不动最后心跳**。
//
// 用在「改了地址或凭据」之后：配置变了，旧的 online/offline 结论不再可信，
// 但一次配置修改并不代表真的连过，把 last_heartbeat 刷成当前时间会误导用户。
func MarkServerUnknown(d *sql.DB, id int64) error {
	res, err := d.Exec(
		`UPDATE servers SET connection_status = 'unknown' WHERE id = ?`, id,
	)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrServerNotFound
	}
	return nil
}

// GetDecryptedCredential 读取并解密某服务器的 SSH 凭据。
func GetDecryptedCredential(d *sql.DB, masterKey string, serverID int64) (*DecryptedCredential, error) {
	var (
		method  string
		passEnc sql.NullString
		keyEnc  sql.NullString
		keyPass sql.NullString
	)
	err := d.QueryRow(
		`SELECT auth_method, password_enc, key_enc, key_pass_enc FROM ssh_credentials WHERE server_id = ?`, serverID,
	).Scan(&method, &passEnc, &keyEnc, &keyPass)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrServerNotFound
	}
	if err != nil {
		return nil, err
	}

	c := &DecryptedCredential{AuthMethod: method}
	if c.Password, err = decryptOptional(masterKey, passEnc); err != nil {
		return nil, err
	}
	if c.PrivateKey, err = decryptOptional(masterKey, keyEnc); err != nil {
		return nil, err
	}
	if c.KeyPass, err = decryptOptional(masterKey, keyPass); err != nil {
		return nil, err
	}
	return c, nil
}

func scanServer(sc interface{ Scan(dest ...any) error }) (*model.Server, error) {
	var s model.Server
	var hb sql.NullTime
	if err := sc.Scan(
		&s.ID, &s.Name, &s.Host, &s.Port, &s.SSHUser, &s.AuthMethod,
		&s.ConnectionStatus, &hb, &s.Tags, &s.CreatedAt,
	); err != nil {
		return nil, err
	}
	if hb.Valid {
		s.LastHeartbeat = &hb.Time
	}
	return &s, nil
}

func encryptOptional(master, plain string) (string, error) {
	if plain == "" {
		return "", nil
	}
	return crypto.Encrypt(master, plain)
}

func decryptOptional(master string, v sql.NullString) (string, error) {
	if !v.Valid || v.String == "" {
		return "", nil
	}
	return crypto.Decrypt(master, v.String)
}
