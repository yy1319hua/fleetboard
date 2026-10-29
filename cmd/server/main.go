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
	"strings"
	"syscall"
	"time"

	"github.com/yy1319hua/fleetboard/internal/api"
	"github.com/yy1319hua/fleetboard/internal/config"
	"github.com/yy1319hua/fleetboard/internal/upgrade"
)

// version 在构建时可通过 -ldflags "-X main.version=..." 注入。
var version = "dev"

func main() {
	api.BuildVersion = version

	// 配置提前加载：自更新管理器要用到安装目录与开关，必须在建路由前就绪。
	// （BuildRouter 内部还会 Load 一次；loadDotEnv 幂等且不覆盖已存在的环境变量，无副作用。）
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "配置加载失败: %v\n", err)
		os.Exit(1)
	}

	// 面板自更新的编排器在此装配：它只依赖文件系统与版本号（与 DB 无关），
	// 由 api 层按依赖注入使用，api 包因此不必反向依赖运维实现细节。
	// 开关取 cfg.UpgradeEnabled（FLEETBOARD_UPGRADE_ENABLED），状态目录复用 DATA_DIR
	// ——与 deploy 里 fleetboard.service 的 ReadWritePaths=/var/lib/fleetboard 对齐。
	baseDir := envOr(api.EnvUpgradeBaseDir, api.DefaultUpgradeBaseDir)
	selfUpgrade := cfg.UpgradeEnabled
	wiring := &api.UpgradeWiring{
		Enabled: selfUpgrade,
		BaseDir: baseDir,
		Manager: upgrade.NewManager(upgrade.Config{
			Dir:     cfg.DataDir,
			BaseDir: baseDir,
			Version: version,
			// Enabled 语义是「环境是否满足」：开关关了就不必再做环境探测。
			Enabled: selfUpgrade && api.UpgradeEnvReady(baseDir),
		}),
	}

	r := api.BuildRouterWithUpgrade(wiring)

	srv := &http.Server{
		Addr:              fmt.Sprintf("%s:%d", cfg.ListenAddr, cfg.Port),
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("fleetboard %s 启动: http://%s (schema 见 /api/health)", version, srv.Addr)
		if selfUpgrade {
			log.Printf("面板自更新已开启（%s=1，安装目录 %s）", api.EnvSelfUpgrade, baseDir)
		}
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

// envOr 读环境变量，空值回落到默认。
// 自更新相关的配置项直接读环境而不进 config.Config：默认安装下它们几乎不变，
// 且 config 包对外已是稳定契约，为一两个启动期开关扩字段不划算。
func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}
