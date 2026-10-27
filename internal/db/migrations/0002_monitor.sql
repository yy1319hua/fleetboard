-- 0002_monitor.sql 监控时序、报警规则、通知中心（前向追加，不改旧列）
CREATE TABLE IF NOT EXISTS server_metrics (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id INTEGER NOT NULL,
    ts        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cpu_pct   REAL NOT NULL DEFAULT 0,
    mem_pct   REAL NOT NULL DEFAULT 0,
    disk_pct  REAL NOT NULL DEFAULT 0,
    load1     REAL NOT NULL DEFAULT 0,
    net_in_kbps  REAL NOT NULL DEFAULT 0,
    net_out_kbps REAL NOT NULL DEFAULT 0
);
-- 按 (server_id, ts) 查历史曲线，复合索引最关键
CREATE INDEX IF NOT EXISTS idx_metrics_server_ts ON server_metrics(server_id, ts);

CREATE TABLE IF NOT EXISTS alert_rules (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id       INTEGER,
    metric          TEXT NOT NULL,
    operator        TEXT NOT NULL DEFAULT '>',
    threshold       REAL NOT NULL DEFAULT 0,
    severity        TEXT NOT NULL DEFAULT 'warn',
    enabled         INTEGER NOT NULL DEFAULT 1,
    notify_channels TEXT NOT NULL DEFAULT 'inapp',
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS alert_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id  INTEGER,
    rule_id    INTEGER,
    severity   TEXT NOT NULL DEFAULT 'info',
    title      TEXT NOT NULL,
    message    TEXT,
    is_read    INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_alert_read_time ON alert_events(is_read, created_at);
CREATE INDEX IF NOT EXISTS idx_alert_server   ON alert_events(server_id);
