// Command server 是 fleetboard 的入口。
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/yy1319hua/fleetboard/internal/api"
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

	if created, err := db.EnsureAdmin(d, cfg.BootstrapUser, cfg.BootstrapPass); err != nil {
		fmt.Fprintf(os.Stderr, "初始化管理员失败: %v\n", err)
		os.Exit(1)
	} else if created {
		log.Printf("已创建初始管理员: %s", cfg.BootstrapUser)
	}

	schema, err := db.Version(d)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取 schema 版本失败: %v\n", err)
		os.Exit(1)
	}

	r := api.NewRouter(api.RouterOptions{
		Version:   version,
		Schema:    schema,
		DB:        d,
		JWTSecret: cfg.JWTSecret,
	})
	srv := &http.Server{
		Addr:              fmt.Sprintf("%s:%d", cfg.ListenAddr, cfg.Port),
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("fleetboard %s 启动: http://%s (schema=%s)", version, srv.Addr, schema)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("HTTP 服务异常: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("收到退出信号，正在关闭...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("关闭异常: %v", err)
	}
}
