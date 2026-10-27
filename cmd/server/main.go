// Command server 是 fleetboard 的入口。
package main

import (
	"fmt"
	"os"

	"github.com/yy1319hua/fleetboard/internal/config"
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
	fmt.Printf("fleetboard %s: listen=%s:%d data_dir=%s db=%s\n",
		version, cfg.ListenAddr, cfg.Port, cfg.DataDir, cfg.DBPath)
}
