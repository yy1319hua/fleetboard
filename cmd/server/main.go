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
)

// version 在构建时可通过 -ldflags "-X main.version=..." 注入。
var version = "dev"

func main() {
	api.BuildVersion = version
	r := api.BuildRouter()

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "配置加载失败: %v\n", err)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:              fmt.Sprintf("%s:%d", cfg.ListenAddr, cfg.Port),
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("fleetboard %s 启动: http://%s (schema 见 /api/health)", version, srv.Addr)
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
	api.StopBackground()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("关闭异常: %v", err)
	}
}
