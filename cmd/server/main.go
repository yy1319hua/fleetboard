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

	"github.com/yy1319hua/fleetboard/internal/alert"
	"github.com/yy1319hua/fleetboard/internal/api"
	"github.com/yy1319hua/fleetboard/internal/config"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
	"github.com/yy1319hua/fleetboard/internal/monitor"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
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

	pool := sshpool.NewPool(10 * time.Minute)
	defer pool.CloseAll()
	stopReap := make(chan struct{})
	defer close(stopReap)
	go func() {
		t := time.NewTicker(5 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				pool.Reap()
			case <-stopReap:
				return
			}
		}
	}()

	stopMonitor := make(chan struct{})
	defer close(stopMonitor)
	go func() {
		// 连续失败计数：达到阈值才判 offline（默认 2 次 × 30s = 60s）
		failCount := make(map[int64]int)
		collect := func() {
			servers, err := db.ListServers(d)
			if err != nil {
				log.Printf("指标采集：列出服务器失败: %v", err)
				return
			}
			for _, s := range servers {
				cred, err := db.GetDecryptedCredential(d, cfg.Key, s.ID)
				if err != nil {
					continue
				}
				ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
				cli, err := pool.Get(ctx, s.ID, sshpool.Config{
					Host:       s.Host,
					Port:       s.Port,
					User:       s.SSHUser,
					AuthMethod: cred.AuthMethod,
					Password:   cred.Password,
					PrivateKey: cred.PrivateKey,
					KeyPass:    cred.KeyPass,
				})
				if err != nil {
					cancel()
					failCount[s.ID]++
					if failCount[s.ID] >= cfg.OfflineThreshold {
						_ = db.UpdateServerStatus(d, s.ID, "offline")
					}
					continue
				}

				snap, err := monitor.Collect(cli)
				cancel()
				if err != nil {
					failCount[s.ID]++
					if failCount[s.ID] >= cfg.OfflineThreshold {
						_ = db.UpdateServerStatus(d, s.ID, "offline")
					}
					continue
				}

				failCount[s.ID] = 0
				if err := db.InsertMetric(d, s.ID, snap.CPUPct, snap.MemPct, snap.DiskPct, snap.Load1); err != nil {
					log.Printf("指标采集：写入 #%d 失败: %v", s.ID, err)
				}
				_ = db.UpdateServerStatus(d, s.ID, "online")

				hits, err := alert.Evaluate(d, s.ID, &model.ServerMetric{
					CPUPct:  snap.CPUPct,
					MemPct:  snap.MemPct,
					DiskPct: snap.DiskPct,
					Load1:   snap.Load1,
				})
				if err != nil {
					log.Printf("告警评估 #%d 失败: %v", s.ID, err)
				} else if hits > 0 {
					log.Printf("告警评估 #%d：命中 %d 条规则", s.ID, hits)
				}
			}
		}

		collect()
		t := time.NewTicker(time.Duration(cfg.MonitorIntervalSec) * time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				collect()
			case <-stopMonitor:
				return
			}
		}
	}()

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
		MasterKey: cfg.Key,
		Pool:      pool,
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
