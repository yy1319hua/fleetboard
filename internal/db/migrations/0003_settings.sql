-- M8.1b: 设置面 KV 存储。
-- settings 表已由 0001_init 建为 (key,value)；此处补 updated_at 并落热生效版本号行。
-- 'revision' 行任何写入都在同事务内自增，读方轮询其变化后重载（PLAN-NEXT §5.1）。
ALTER TABLE settings ADD COLUMN updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP;

INSERT OR IGNORE INTO settings(key, value) VALUES ('revision', '0');
