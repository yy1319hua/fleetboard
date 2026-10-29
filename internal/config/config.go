// Package config 负责配置加载与校验。
package config

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config 汇总服务启动所需的配置，全部来自环境变量（可辅以 .env）。
type Config struct {
	ListenAddr           string   // HTTP 监听地址，默认 127.0.0.1（公网仅经 Cloudflare Tunnel）
	Port                 int      // HTTP 监听端口
	DataDir              string   // 数据目录（SQLite、日志等）
	DBPath               string   // SQLite 文件路径
	Key                  string   // 凭据加密主密钥（AES-256-GCM），绝不落库明文
	JWTSecret            string   // JWT 签名密钥
	BootstrapUser        string   // 首次启动创建的管理员用户名
	BootstrapPass        string   // 首次启动创建的管理员密码
	MonitorIntervalSec   int      // 指标采集间隔（秒）
	MetricsRetentionDays int      // 指标保留天数
	OfflineThreshold     int      // 连续失败多少次判定离线
	PushPlusToken        string   // PushPlus 告警通道 token
	ComposeRoots         []string // compose 文件可读写根目录白名单（空=用内置默认）
	UpgradeEnabled       bool     // 面板自更新开关（FLEETBOARD_UPGRADE_ENABLED，1/true 为开，默认关）
}

// Load 先加载 .env（若存在），再读取环境变量，返回校验通过的配置。
func Load() (*Config, error) {
	if err := loadDotEnv(".env"); err != nil {
		return nil, err
	}

	cfg := &Config{
		ListenAddr:    getenv("LISTEN_ADDR", "127.0.0.1"),
		DataDir:       getenv("DATA_DIR", "./data"),
		Key:           os.Getenv("KEY"),
		JWTSecret:     os.Getenv("JWT_SECRET"),
		BootstrapUser: os.Getenv("BOOTSTRAP_USER"),
		BootstrapPass: os.Getenv("BOOTSTRAP_PASS"),
		PushPlusToken: os.Getenv("PUSHPLUS_TOKEN"),
	}

	var err error
	if cfg.Port, err = getenvInt("PORT", 8080); err != nil {
		return nil, err
	}
	if cfg.MonitorIntervalSec, err = getenvInt("MONITOR_INTERVAL", 30); err != nil {
		return nil, err
	}
	if cfg.MetricsRetentionDays, err = getenvInt("METRICS_RETENTION_DAYS", 30); err != nil {
		return nil, err
	}
	if cfg.OfflineThreshold, err = getenvInt("OFFLINE_THRESHOLD", 2); err != nil {
		return nil, err
	}

	cfg.DBPath = getenv("DB_PATH", cfg.DataDir+"/fleetboard.db")
	cfg.ComposeRoots = splitCSV(os.Getenv("COMPOSE_ROOTS"))
	// 自更新是危险操作（会停服、换二进制），默认关闭，必须显式打开
	cfg.UpgradeEnabled = getenvBool("FLEETBOARD_UPGRADE_ENABLED")

	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// Validate 校验关键配置与取值范围。
func (c *Config) Validate() error {
	if strings.TrimSpace(c.Key) == "" {
		return errors.New("缺少 KEY（凭据加密主密钥），请通过环境变量或 .env 提供")
	}
	// JWT_SECRET 已入库 settings（M8.1b）：env 有值则首启吸收，无值自动生成，此处不再强校验
	if c.Port <= 0 || c.Port > 65535 {
		return fmt.Errorf("PORT 超出范围: %d", c.Port)
	}
	if c.MonitorIntervalSec <= 0 {
		return fmt.Errorf("MONITOR_INTERVAL 必须为正数: %d", c.MonitorIntervalSec)
	}
	if c.MetricsRetentionDays <= 0 {
		return fmt.Errorf("METRICS_RETENTION_DAYS 必须为正数: %d", c.MetricsRetentionDays)
	}
	if c.OfflineThreshold <= 0 {
		return fmt.Errorf("OFFLINE_THRESHOLD 必须为正数: %d", c.OfflineThreshold)
	}
	return nil
}

// EnsureDataDir 确保数据目录存在（权限 0700）。
func (c *Config) EnsureDataDir() error {
	return os.MkdirAll(c.DataDir, 0o700)
}

// loadDotEnv 解析 KEY=VALUE 形式的 .env；已存在的环境变量不覆盖；文件不存在时静默返回 nil。
func loadDotEnv(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.Trim(strings.TrimSpace(v), `"'`)
		if k == "" {
			continue
		}
		if _, exists := os.LookupEnv(k); exists {
			continue
		}
		if err := os.Setenv(k, v); err != nil {
			return err
		}
	}
	return sc.Err()
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// getenvBool 解析布尔型环境变量：仅 "1"/"true" 视为开（大小写不敏感），其余一律关。
// 严格只认这两个取值，避免 "off"/"0"/"no" 之类写法产生歧义。
func getenvBool(k string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(k))) {
	case "1", "true":
		return true
	}
	return false
}

func getenvInt(k string, def int) (int, error) {
	v := os.Getenv(k)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return 0, fmt.Errorf("%s 需为整数，实际 %q", k, v)
	}
	return n, nil
}

// splitCSV 把逗号分隔的配置项拆成切片，去空与首尾空白。
func splitCSV(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
