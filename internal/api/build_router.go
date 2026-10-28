package api

import (
	"context"
	"database/sql"
	"log"
	"os"
	"time"

	"github.com/yy1319hua/fleetboard/internal/alert"
	"github.com/yy1319hua/fleetboard/internal/config"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
	"github.com/yy1319hua/fleetboard/internal/monitor"
	"github.com/yy1319hua/fleetboard/internal/settings"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"github.com/gin-gonic/gin"
)

// BuildVersion 由 main 在启动时从 -ldflags 注入，供 /api/bootstrap 与 /api/health 返回。
var BuildVersion = "dev"

// 后台服务与资源句柄，供 StopBackground 优雅退出时释放。
var (
	bgStop chan struct{}
	bgDB   *sql.DB
	bgPool *sshpool.Pool
)

// BuildRouter 构建完整 HTTP 引擎（含配置加载、数据库、设置、连接池与后台服务），
// 但不调用 r.Run()/ListenAndServe，便于契约测试复用同一引擎。
func BuildRouter() *gin.Engine {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("配置加载失败: %v", err)
	}
	if err := cfg.EnsureDataDir(); err != nil {
		log.Fatalf("创建数据目录失败: %v", err)
	}

	d, err := db.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("数据库初始化失败: %v", err)
	}

	store, err := settings.Load(d, cfg.Key)
	if err != nil {
		log.Fatalf("加载设置失败: %v", err)
	}
	if jwtSecret, ok, err := store.Get("jwt.secret"); err != nil {
		log.Fatalf("读取 jwt.secret 失败: %v", err)
	} else if ok {
		cfg.JWTSecret = jwtSecret
	}

	pool := sshpool.NewPool(10 * time.Minute)

	if _, _, _, _, err := db.EnsureBootstrapAdmin(d, cfg.BootstrapUser, cfg.BootstrapPass); err != nil {
		log.Fatalf("初始化管理员失败: %v", err)
	}

	schema, err := db.Version(d)
	if err != nil {
		log.Fatalf("读取 schema 版本失败: %v", err)
	}

	stop := make(chan struct{})
	runBackground(d, store, pool, cfg.Key, cfg.PushPlusToken, stop)

	bgStop = stop
	bgDB = d
	bgPool = pool

	return NewRouter(RouterOptions{
		Version:      BuildVersion,
		Schema:       schema,
		DB:           d,
		JWTSecret:    cfg.JWTSecret,
		MasterKey:    cfg.Key,
		Pool:         pool,
		Settings:     store,
		Port:         cfg.Port,
		ComposeRoots: cfg.ComposeRoots,
		WebDir:       os.Getenv("WEB_DIR"),
	})
}

// StopBackground 优雅停止后台服务并释放连接池 / 数据库（main 在退出信号后调用）。
func StopBackground() {
	if bgStop != nil {
		close(bgStop)
	}
	if bgPool != nil {
		bgPool.CloseAll()
	}
	if bgDB != nil {
		_ = bgDB.Close()
	}
}

// runBackground 启动指标采集 / 告警评估 / 指标清理 / 连接池回收等后台 goroutine，
// 与 main 原有逻辑一致；stop 关闭时各 goroutine 退出。
func runBackground(d *sql.DB, store *settings.Store, pool *sshpool.Pool, masterKey, pushPlusToken string, stop <-chan struct{}) {
	// 连接池回收
	go func() {
		t := time.NewTicker(5 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				pool.Reap()
			case <-stop:
				return
			}
		}
	}()

	// 指标采集 + 告警评估
	go func() {
		failCount := make(map[int64]int)
		collect := func() {
			servers, err := db.ListServers(d)
			if err != nil {
				log.Printf("指标采集：列出服务器失败: %v", err)
				return
			}
			for _, s := range servers {
				cred, err := db.GetDecryptedCredential(d, masterKey, s.ID)
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
				}, store.GetOr("pushplus.token", pushPlusToken))
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
				if iv := store.Int("monitor.interval", 30); iv != interval {
					interval = iv
					t.Reset(time.Duration(iv) * time.Second)
					log.Printf("采集间隔热更新为 %ds", iv)
				}
			case <-stop:
				return
			}
		}
	}()

	// 指标清理
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
			case <-stop:
				return
			}
		}
	}()
}
