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
	"github.com/yy1319hua/fleetboard/internal/settings"
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

	// 设置面（M8.1b/M8.1d）：settings.Load 吸收 env（含 JWT_SECRET）→ 无则自动生成 jwt.secret。
	// 必须先于监控 goroutine 加载，采集/告警/prune 每轮从 store 取值实现热生效。
	store, err := settings.Load(d, cfg.Key)
	if err != nil {
		fmt.Fprintf(os.Stderr, "加载设置失败: %v\n", err)
		os.Exit(1)
	}
	// 优先级 DB > env：DB 里的 jwt.secret 恒生效（env 值已在 Load 时吸收）
	if jwtSecret, ok, err := store.Get("jwt.secret"); err != nil {
		fmt.Fprintf(os.Stderr, "读取 jwt.secret 失败: %v\n", err)
		os.Exit(1)
	} else if ok {
		cfg.JWTSecret = jwtSecret
	}

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
					if failCount[s.ID] >= store.Int("monitor.offline_threshold", 2) {
						_ = db.UpdateServerStatus(d, s.ID, "offline")
					}
					continue
				}

				snap, err := monitor.Collect(cli)
				cancel()
				if err != nil {
					failCount[s.ID]++
					if failCount[s.ID] >= store.Int("monitor.offline_threshold", 2) {
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
				}, store.GetOr("pushplus.token", cfg.PushPlusToken))
				if err != nil {
					log.Printf("告警评估 #%d 失败: %v", s.ID, err)
				} else if hits > 0 {
					log.Printf("告警评估 #%d：命中 %d 条规则", s.ID, hits)
				}
			}
		}

		collect()
		interval := store.Int("monitor.interval", 30)
		t := time.NewTicker(time.Duration(interval) * time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				collect()
				// M8.1d 热生效：每轮读 settings，间隔变化即 Reset
				if iv := store.Int("monitor.interval", 30); iv != interval {
					interval = iv
					t.Reset(time.Duration(iv) * time.Second)
					log.Printf("采集间隔热更新为 %ds", iv)
				}
			case <-stopMonitor:
				return
			}
		}
	}()

	stopPrune := make(chan struct{})
	defer close(stopPrune)
	go func() {
		prune := func() {
			cutoff := time.Now().AddDate(0, 0, -store.Int("metrics.retention_days", 30))
			n, err := db.PruneMetrics(d, cutoff)
			if err != nil {
				log.Printf("指标清理失败: %v", err)
				return
			}
			if n > 0 {
				log.Printf("指标清理：删除 %d 条早于 %s 的采样", n, cutoff.Format("2006-01-02"))
			}
		}
		prune()
		t := time.NewTicker(24 * time.Hour)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				prune()
			case <-stopPrune:
				return
			}
		}
	}()

	if user, pass, generated, created, err := db.EnsureBootstrapAdmin(d, cfg.BootstrapUser, cfg.BootstrapPass); err != nil {
		fmt.Fprintf(os.Stderr, "初始化管理员失败: %v\n", err)
		os.Exit(1)
	} else if created {
		if generated {
			// M8.1a 自举兜底：仅显示这一次，安装脚本会从日志提取展示
			log.Printf("首次启动自举：已生成管理员账密 %s / %s（仅显示这一次，请立即记录）", user, pass)
		} else {
			log.Printf("已创建初始管理员: %s", user)
		}
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
		Settings:  store,
		Port:      cfg.Port,

		ComposeRoots: cfg.ComposeRoots,
		WebDir:       os.Getenv("WEB_DIR"),
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
