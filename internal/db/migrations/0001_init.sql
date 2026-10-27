-- 0001_init.sql 核心表：用户、服务器、SSH 凭据、操作审计、全局设置、文件缓存
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS servers (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL,
    host              TEXT NOT NULL,
    port              INTEGER NOT NULL DEFAULT 22,
    ssh_user          TEXT NOT NULL DEFAULT 'root',
    auth_method       TEXT NOT NULL DEFAULT 'key',
    connection_status TEXT NOT NULL DEFAULT 'unknown',
    last_heartbeat    DATETIME,
    tags              TEXT DEFAULT '',
    created_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS ssh_credentials (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id    INTEGER NOT NULL UNIQUE REFERENCES servers(id) ON DELETE CASCADE,
    auth_method  TEXT NOT NULL,
    password_enc TEXT,
    key_enc      TEXT,
    key_pass_enc TEXT
);

CREATE TABLE IF NOT EXISTS operation_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL,
    server_id  INTEGER,
    action     TEXT NOT NULL,
    detail     TEXT,
    result     TEXT NOT NULL DEFAULT 'ok',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_op_log_server ON operation_log(server_id);
CREATE INDEX IF NOT EXISTS idx_op_log_time   ON operation_log(created_at);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS file_cache (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id  INTEGER NOT NULL,
    path       TEXT NOT NULL,
    listing    TEXT,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(server_id, path)
);
CREATE INDEX IF NOT EXISTS idx_file_cache_server ON file_cache(server_id);
