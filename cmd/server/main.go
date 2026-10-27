// Command server 是 fleetboard 的入口。
package main

import (
	"fmt"
	"os"

	"github.com/yy1319hua/fleetboard/internal/config"
	"github.com/yy1319hua/fleetboard/internal/db"
)

// version 在构建时可通过 -ldflags "-X main.version=..." 注入。
var version = "dev"

func main() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "配置加载失败: %v\n", err)
		os.Exit(1)
	}
	if err := cfg.EnsureDataDir(); err != nil {
		fmt.Fprintf(os.Stderr, "创建数据目录失败: %v\n", err)
		os.Exit(1)
	}

	d, err := db.Open(cfg.DBPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "数据库初始化失败: %v\n", err)
		os.Exit(1)
	}
	defer d.Close()

	schema, err := db.Version(d)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取 schema 版本失败: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("fleetboard %s: listen=%s:%d db=%s schema=%s\n",
		version, cfg.ListenAddr, cfg.Port, cfg.DBPath, schema)
}
