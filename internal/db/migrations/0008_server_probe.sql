-- 0008_server_probe.sql 首次保存时的一次性体检结果
--
-- has_docker / has_sftp 三态：-1 = 未检测（升级前的老数据）、0 = 不支持、1 = 支持。
-- 用 -1 而不是 0 作默认值：如果默认 0，升级后所有历史机器都会被判成「没有 docker」
-- 而把容器 Tab 藏掉，用户会以为功能丢了。前端遇到 -1 时按「全都显示」处理，
-- 并在详情页给一次手动检测入口。
ALTER TABLE server_facts ADD COLUMN has_docker INTEGER NOT NULL DEFAULT -1;
ALTER TABLE server_facts ADD COLUMN has_sftp INTEGER NOT NULL DEFAULT -1;
-- probed_at 与 collected_at 分开：配置可能在很久以前采的，但能力是刚探的。
ALTER TABLE server_facts ADD COLUMN probed_at DATETIME;
