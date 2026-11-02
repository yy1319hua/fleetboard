-- 0006_server_facts.sql 主机静态配置（概览「系统配置」卡的数据源）
-- 一服务器一行：配置基本不变，按小时刷新覆盖，不需要历史。
-- 与 server_metrics 分开的理由：metrics 是 30 秒一条的时序，facts 是低频快照；
-- 混在一张表里会让每次采样都重复写 10 个几乎不变的字段，且降采样查询要额外过滤。
CREATE TABLE IF NOT EXISTS server_facts (
  server_id     INTEGER PRIMARY KEY REFERENCES servers(id) ON DELETE CASCADE,
  cpu_model     TEXT    NOT NULL DEFAULT '',
  cpu_cores     INTEGER NOT NULL DEFAULT 0,   -- 逻辑线程数（/proc/cpuinfo 的 processor 数）
  mem_total_kb  INTEGER NOT NULL DEFAULT 0,
  swap_total_kb INTEGER NOT NULL DEFAULT 0,
  os_name       TEXT    NOT NULL DEFAULT '',
  kernel        TEXT    NOT NULL DEFAULT '',
  arch          TEXT    NOT NULL DEFAULT '',
  hostname      TEXT    NOT NULL DEFAULT '',
  uptime_sec    INTEGER NOT NULL DEFAULT 0,
  virt          TEXT    NOT NULL DEFAULT '',   -- systemd-detect-virt：kvm / docker / none
  disks_json    TEXT    NOT NULL DEFAULT '[]', -- [{"device","mount","total_kb","used_kb","avail_kb","used_pct"}]
  collected_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
