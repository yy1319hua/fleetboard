-- M8.1e: JWT ver epoch（token 版本号）。
-- 改密/注销会话时自增，旧 access/refresh 携带的 ver 不匹配即 401——
-- 修复无状态 refresh 7 天硬墙无法吊销的问题（PLAN-NEXT §5.1 / 裁决 4）。
ALTER TABLE users ADD COLUMN token_ver INTEGER NOT NULL DEFAULT 0;
