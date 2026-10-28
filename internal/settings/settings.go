// Package settings 提供基于 settings 表的运行期配置存储。
//
// 设计（PLAN-NEXT §5.1）：KV 行存 + spec 注册表 + revision 轮询热生效。
// 取值优先级：DB settings > 环境变量（首启吸收）> 内置默认。
// 敏感值 AES-256-GCM 加密落库，对外只回尾 4 位掩码。
package settings

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"

	"github.com/yy1319hua/fleetboard/internal/crypto"
)

// Kind 描述设置值的类型。
type Kind int

const (
	KindString Kind = iota
	KindInt
	KindCSV // 逗号分隔字符串列表
)

// Spec 是单个设置项的定义。
type Spec struct {
	Key     string // 点分 key，如 monitor.interval
	Kind    Kind
	Secret  bool   // 加密落库，GET 只回尾 4 位
	Default string // 无 DB 无 env 时的默认值
	EnvKey  string // 首启吸收来源环境变量名
}

// registry 是全部受支持的设置项。新增项只需在此追加。
var registry = []Spec{
	{Key: "monitor.interval", Kind: KindInt, Default: "30", EnvKey: "MONITOR_INTERVAL"},
	{Key: "metrics.retention_days", Kind: KindInt, Default: "30", EnvKey: "METRICS_RETENTION_DAYS"},
	{Key: "monitor.offline_threshold", Kind: KindInt, Default: "2", EnvKey: "OFFLINE_THRESHOLD"},
	{Key: "compose.roots", Kind: KindCSV, Default: "", EnvKey: "COMPOSE_ROOTS"},
	{Key: "pushplus.token", Kind: KindString, Secret: true, Default: "", EnvKey: "PUSHPLUS_TOKEN"},
	{Key: "jwt.secret", Kind: KindString, Secret: true, Default: "", EnvKey: "JWT_SECRET"},
}

// RevisionKey 是热生效版本号所在行，禁止通过 API 修改。
const RevisionKey = "revision"

func specs() map[string]Spec {
	m := make(map[string]Spec, len(registry))
	for _, s := range registry {
		m[s.Key] = s
	}
	return m
}

// Store 是 settings 表的内存缓存视图。Get/Snapshot 先轮询 revision，
// 变化了才重读全表（PLAN-NEXT §5.1 热生效裁决）。
type Store struct {
	db  *sql.DB
	key string // 主密钥

	mu   sync.RWMutex
	rev  int64
	vals map[string]string // 解密后的明文
}

// Load 打开存储：首启吸收环境变量（原值写入 DB），随后加载全表缓存。
// jwt.secret 若 DB 与 env 均缺省则自动生成随机值入库。
func Load(d *sql.DB, masterKey string) (*Store, error) {
	s := &Store{db: d, key: masterKey, vals: map[string]string{}}
	if err := s.absorbEnv(); err != nil {
		return nil, err
	}
	if err := s.refresh(); err != nil {
		return nil, err
	}
	return s, nil
}

// absorbEnv 把「DB 无此行且 env 有值」的项原值写入 DB（secret 加密）。
// 之后 env 再改动不生效（优先级 DB > env），只认 DB。
func (s *Store) absorbEnv() error {
	for _, spec := range registry {
		var exists int
		if err := s.db.QueryRow(`SELECT COUNT(1) FROM settings WHERE key = ?`, spec.Key).Scan(&exists); err != nil {
			return fmt.Errorf("查询 %s: %w", spec.Key, err)
		}
		if exists > 0 {
			continue
		}
		v := spec.Default
		if spec.EnvKey != "" {
			if env := strings.TrimSpace(os.Getenv(spec.EnvKey)); env != "" {
				v = env
			}
		}
		if spec.Key == "jwt.secret" && v == "" {
			generated, err := randomSecret()
			if err != nil {
				return fmt.Errorf("生成 jwt.secret: %w", err)
			}
			v = generated
		}
		if v == "" {
			continue // 默认也为空：不入库，读取时回落默认
		}
		if err := s.upsertRaw(spec.Key, v, spec.Secret); err != nil {
			return err
		}
	}
	return nil
}

// upsertRaw 写入单个 key（按需加密），并在同事务内自增 revision。
func (s *Store) upsertRaw(key, value string, secret bool) error {
	stored := value
	if secret {
		enc, err := crypto.Encrypt(s.key, value)
		if err != nil {
			return fmt.Errorf("加密 %s: %w", key, err)
		}
		stored = enc
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`INSERT INTO settings(key, value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP`, key, stored); err != nil {
		return fmt.Errorf("写入 %s: %w", key, err)
	}
	if key != RevisionKey {
		if _, err := tx.Exec(`UPDATE settings SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = ?`, RevisionKey); err != nil {
			return fmt.Errorf("自增 revision: %w", err)
		}
	}
	return tx.Commit()
}

// refresh 轮询 revision，变化则重读全表并解密 secret。
func (s *Store) refresh() error {
	var revStr string
	if err := s.db.QueryRow(`SELECT value FROM settings WHERE key = ?`, RevisionKey).Scan(&revStr); err != nil {
		return fmt.Errorf("读取 revision: %w", err)
	}
	rev, err := strconv.ParseInt(strings.TrimSpace(revStr), 10, 64)
	if err != nil {
		return fmt.Errorf("revision 非整数: %q", revStr)
	}

	s.mu.RLock()
	unchanged := rev == s.rev
	s.mu.RUnlock()
	if unchanged {
		return nil
	}

	rows, err := s.db.Query(`SELECT key, value FROM settings WHERE key != ?`, RevisionKey)
	if err != nil {
		return err
	}
	defer rows.Close()

	vals := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return err
		}
		if spec, ok := specs()[k]; ok && spec.Secret {
			pt, err := crypto.Decrypt(s.key, v)
			if err != nil {
				return fmt.Errorf("解密 %s（KEY 是否变更？）: %w", k, err)
			}
			v = pt
		}
		vals[k] = v
	}
	if err := rows.Err(); err != nil {
		return err
	}

	s.mu.Lock()
	s.rev, s.vals = rev, vals
	s.mu.Unlock()
	return nil
}

// Get 返回 key 的明文值与是否存在（不存在时返回 spec 默认值）。
func (s *Store) Get(key string) (string, bool, error) {
	if err := s.refresh(); err != nil {
		return "", false, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if v, ok := s.vals[key]; ok {
		return v, true, nil
	}
	spec, ok := specs()[key]
	if !ok {
		return "", false, fmt.Errorf("未知设置项: %s", key)
	}
	return spec.Default, false, nil
}

// Snapshot 返回全部设置明文（供采集/告警循环取快照，M8.1d 接线）。
func (s *Store) Snapshot() (map[string]string, error) {
	if err := s.refresh(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]string, len(s.vals))
	for k, v := range s.vals {
		out[k] = v
	}
	return out, nil
}

// Rev 返回当前 revision。
func (s *Store) Rev() int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.rev
}

// MaskedView 生成对外视图：secret 回 {"masked":"****abcd","set":true}，其余回原值。
func (s *Store) MaskedView() (map[string]any, error) {
	if err := s.refresh(); err != nil {
		return nil, err
	}
	out := map[string]any{}
	for _, spec := range registry {
		s.mu.RLock()
		v, set := s.vals[spec.Key]
		s.mu.RUnlock()
		if spec.Secret {
			if !set {
				out[spec.Key] = map[string]any{"masked": "", "set": false}
				continue
			}
			tail := v
			if len(tail) > 4 {
				tail = tail[len(tail)-4:]
			}
			out[spec.Key] = map[string]any{"masked": "****" + tail, "set": true}
			continue
		}
		out[spec.Key] = v
	}
	return out, nil
}

// Validate 校验待写入值是否符合 spec（类型/范围）。
func Validate(spec Spec, value string) error {
	switch spec.Kind {
	case KindInt:
		n, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return fmt.Errorf("%s 需为整数，实际 %q", spec.Key, value)
		}
		if n <= 0 {
			return fmt.Errorf("%s 必须为正数: %d", spec.Key, n)
		}
	case KindCSV:
		if strings.TrimSpace(value) == "" {
			return nil // 空 = 清空（回落内置默认）
		}
		for _, p := range strings.Split(value, ",") {
			if strings.TrimSpace(p) == "" {
				return fmt.Errorf("%s 存在空项: %q", spec.Key, value)
			}
		}
	default:
		if spec.Secret && strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s 不能为空", spec.Key)
		}
	}
	return nil
}

// Lookup 按名字查询设置项定义。
func Lookup(key string) (Spec, bool) {
	sp, ok := specs()[key]
	return sp, ok
}

// DB 暴露底层连接（测试与审计用）。
func (s *Store) DB() *sql.DB { return s.db }

// GetOr 取明文值；未设置、为空或读取出错时回落 def。
func (s *Store) GetOr(key, def string) string {
	if v, ok, err := s.Get(key); err == nil && ok && strings.TrimSpace(v) != "" {
		return v
	}
	return def
}

// Int 取整数设置项；未设置、非法或 <=0 时回落 def。
func (s *Store) Int(key string, def int) int {
	if v, ok, err := s.Get(key); err == nil && ok {
		if n, perr := strconv.Atoi(strings.TrimSpace(v)); perr == nil && n > 0 {
			return n
		}
	}
	return def
}

// Set 批量写入（逐项校验 + secret 加密），整批一个事务、revision 只自增一次。
func (s *Store) Set(updates map[string]string) error {
	specs := specs()
	// 先整体校验，任一非法则全批拒绝。
	for k, v := range updates {
		spec, ok := specs[k]
		if !ok {
			return fmt.Errorf("未知设置项: %s", k)
		}
		if k == RevisionKey {
			return fmt.Errorf("%s 为内部版本号，禁止修改", RevisionKey)
		}
		if err := Validate(spec, v); err != nil {
			return err
		}
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for k, v := range updates {
		stored := v
		if specs[k].Secret {
			enc, err := crypto.Encrypt(s.key, v)
			if err != nil {
				return fmt.Errorf("加密 %s: %w", k, err)
			}
			stored = enc
		}
		if _, err := tx.Exec(upsertSQL, k, stored); err != nil {
			return fmt.Errorf("写入 %s: %w", k, err)
		}
	}
	if _, err := tx.Exec(`UPDATE settings SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = ?`, RevisionKey); err != nil {
		return fmt.Errorf("自增 revision: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.refresh()
}

// upsertSQL 单行 UPSERT（value 由调用方按需加密）。
const upsertSQL = `INSERT INTO settings(key, value) VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = CURRENT_TIMESTAMP`

func randomSecret() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
