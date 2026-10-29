-- 0005_system_upgrades.sql 面板自更新历史（M7：App 可触发/跟踪自更新）
-- 一行 = 一次升级尝试。真实状态以 internal/upgrade 的状态文件为准（跨进程存活），
-- 本表只做历史留痕与 App 列表展示，因此允许 status 停留在 interrupted
-- （进程在升级中途被杀 = 状态文件与 DB 都停在非终态，启动对账时补写）。
CREATE TABLE IF NOT EXISTS system_upgrades (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  from_version  TEXT    NOT NULL,
  to_version    TEXT    NOT NULL,
  status        TEXT    NOT NULL,          -- in_progress | done | failed | rolled_back | interrupted
  started_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at   DATETIME,
  duration_ms   INTEGER NOT NULL DEFAULT 0,
  error_code    TEXT    NOT NULL DEFAULT '',
  triggered_by  INTEGER,
  log_path      TEXT    NOT NULL DEFAULT ''
);
-- 列表页只按「最近」取，DESC 复合索引让分页稳定（同秒写入靠 id 兜底排序）
CREATE INDEX IF NOT EXISTS idx_system_upgrades_started ON system_upgrades(started_at DESC, id DESC);
