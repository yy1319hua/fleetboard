package model

import "time"

// Server 被管服务器元信息。ssh_user 支持每服务器独立（默认 root）。
type Server struct {
	ID               int64      `json:"id"`
	Name             string     `json:"name"`
	Host             string     `json:"host"`
	Port             int        `json:"port"`
	SSHUser          string     `json:"ssh_user"`
	AuthMethod       string     `json:"auth_method"`       // "password" | "key"
	ConnectionStatus string     `json:"connection_status"` // "online" | "offline" | "unknown"
	LastHeartbeat    *time.Time `json:"last_heartbeat"`
	Tags             string     `json:"tags"`
	CreatedAt        time.Time  `json:"created_at"`
}

// SSHCredential 与 Server 一对一，私钥经 AES-256-GCM 加密存储，绝不落明文。
type SSHCredential struct {
	ID          int64  `json:"-"`
	ServerID    int64  `json:"-"`
	AuthMethod  string `json:"-"`
	PasswordEnc string `json:"-"` // 加密后的口令
	KeyEnc      string `json:"-"` // 加密后的私钥
	KeyPassEnc  string `json:"-"` // 加密后的私钥口令（可选）
}

// User 单人使用，但保留账户模型以便将来扩展。
type User struct {
	ID           int64     `json:"id"`
	Username     string    `json:"username"`
	PasswordHash string    `json:"-"`
	TokenVer     int64     `json:"-"` // JWT ver epoch：改密/注销时自增，旧 token 全失效
	CreatedAt    time.Time `json:"created_at"`
}

// OperationLog 全量操作审计：谁、对哪台、干了什么、结果。
type OperationLog struct {
	ID        int64     `json:"id"`
	UserID    int64     `json:"user_id"`
	ServerID  *int64    `json:"server_id"`
	Action    string    `json:"action"`
	Detail    string    `json:"detail"`
	Result    string    `json:"result"` // "ok" | "fail"
	CreatedAt time.Time `json:"created_at"`
}

// Setting 全局键值配置（pushplus_token 等敏感值加密存储）。
type Setting struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// ServerMetric 时序采样点（server_metrics），按 (server_id, ts) 建复合索引。
type ServerMetric struct {
	ID       int64     `json:"id"`
	ServerID int64     `json:"server_id"`
	TS       time.Time `json:"ts"`
	CPUPct   float64   `json:"cpu_pct"`
	MemPct   float64   `json:"mem_pct"`
	DiskPct  float64   `json:"disk_pct"`
	Load1    float64   `json:"load1"`
	NetIn    float64   `json:"net_in_kbps"`
	NetOut   float64   `json:"net_out_kbps"`
}

// AlertRule 阈值报警规则，server_id 为 NULL 表示全局。
type AlertRule struct {
	ID             int64     `json:"id"`
	ServerID       *int64    `json:"server_id"`
	Metric         string    `json:"metric"`   // cpu_pct|mem_pct|disk_pct|offline
	Operator       string    `json:"operator"` // >|<|=
	Threshold      float64   `json:"threshold"`
	Severity       string    `json:"severity"` // info|warn|critical
	Enabled        bool      `json:"enabled"`
	NotifyChannels string    `json:"notify_channels"` // 如 "inapp,pushplus"
	CreatedAt      time.Time `json:"created_at"`
}

// AlertEvent 通知中心收件箱条目。
type AlertEvent struct {
	ID        int64     `json:"id"`
	ServerID  *int64    `json:"server_id"`
	RuleID    *int64    `json:"rule_id"`
	Severity  string    `json:"severity"`
	Title     string    `json:"title"`
	Message   string    `json:"message"`
	IsRead    bool      `json:"is_read"`
	CreatedAt time.Time `json:"created_at"`
}
