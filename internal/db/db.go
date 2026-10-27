// Package db 负责 SQLite 连接与版本化迁移。
package db

import (
	"database/sql"
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// Open 打开（或创建）SQLite 数据库，并把 schema 迁移到最新版本。
//
// SQLite 单文件 + 单写连接（SetMaxOpenConns(1)）对个人几十台规模足够，且规避并发写锁。
func Open(dbPath string) (*sql.DB, error) {
	if dir := filepath.Dir(dbPath); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("创建数据目录: %w", err)
		}
	}

	d, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("打开数据库: %w", err)
	}
	d.SetMaxOpenConns(1)
	if err := d.Ping(); err != nil {
		_ = d.Close()
		return nil, fmt.Errorf("连接数据库: %w", err)
	}
	if err := ensureSchema(d); err != nil {
		_ = d.Close()
		return nil, err
	}
	return d, nil
}

// ensureSchema 建 schema_migrations 表，并按文件名顺序应用尚未执行的迁移。
// 每个迁移在独立事务内执行，失败即回滚且不记录版本，保证可重试。
func ensureSchema(d *sql.DB) error {
	if _, err := d.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version    TEXT PRIMARY KEY,
		applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
	)`); err != nil {
		return fmt.Errorf("创建 schema_migrations 表: %w", err)
	}

	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return fmt.Errorf("读取迁移目录: %w", err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	for _, f := range files {
		var n int
		if err := d.QueryRow(`SELECT COUNT(1) FROM schema_migrations WHERE version = ?`, f).Scan(&n); err != nil {
			return fmt.Errorf("查询迁移状态 %s: %w", f, err)
		}
		if n > 0 {
			continue
		}

		body, err := migrationsFS.ReadFile("migrations/" + f)
		if err != nil {
			return fmt.Errorf("读取迁移 %s: %w", f, err)
		}

		tx, err := d.Begin()
		if err != nil {
			return fmt.Errorf("开启事务 %s: %w", f, err)
		}
		if _, err := tx.Exec(string(body)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("应用迁移 %s: %w", f, err)
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations(version) VALUES (?)`, f); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("记录迁移 %s: %w", f, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("提交迁移 %s: %w", f, err)
		}
	}
	return nil
}

// Version 返回当前已应用的最新迁移版本；无迁移时返回空串。
func Version(d *sql.DB) (string, error) {
	var v sql.NullString
	if err := d.QueryRow(`SELECT MAX(version) FROM schema_migrations`).Scan(&v); err != nil {
		return "", err
	}
	return v.String, nil
}
