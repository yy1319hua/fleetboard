-- 0007_server_monitor.sql 服务器是否纳入周期性监控
--
-- 「仅保存」的服务器（共享主机、按流量计费或对连接频率敏感的机器）只保留
-- 配置与凭据，供用户手动打开终端 / 文件 / 容器时使用；后台采集循环跳过它们，
-- 避免默认 30 秒一次的 SSH 轮询把端口打到限流甚至封禁。
--
-- 默认 1：历史记录与既有行为不变（此前所有服务器都参与轮询）。
ALTER TABLE servers ADD COLUMN monitor_enabled INTEGER NOT NULL DEFAULT 1;
