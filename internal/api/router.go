package api

import (
	"database/sql"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/settings"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// RouterOptions 是构建路由所需的运行期信息。
type RouterOptions struct {
	Version      string // 服务版本
	Schema       string // 当前数据库迁移版本
	DB           *sql.DB
	JWTSecret    string
	MasterKey    string // 凭据加密主密钥（KEY）
	Pool         *sshpool.Pool
	Settings     *settings.Store // 运行期设置（M8.1b；nil 时设置端点返回 500）
	Port         int             // 只读展示用（M8.1c）
	ComposeRoots []string        // compose 文件可读写根目录白名单（空=内置默认）
	WebDir       string          // 前端构建产物目录（web/dist）；空或不存在则不托管静态资源
}

// NewRouter 构建 HTTP 路由。
func NewRouter(opts RouterOptions) *gin.Engine {
	// 未显式指定 GIN_MODE 时默认 release，避免生产打印 debug 路由信息。
	if os.Getenv("GIN_MODE") == "" && gin.Mode() == gin.DebugMode {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())

	// 公开端点
	r.GET("/api/health", func(c *gin.Context) {
		data := gin.H{
			"status":  "ok",
			"version": opts.Version,
			"schema":  opts.Schema,
		}
		if opts.Settings != nil {
			data["config_rev"] = opts.Settings.Rev()
		}
		OK(c, data)
	})
	r.POST("/api/login", loginHandler(opts.DB, opts.JWTSecret))
	r.POST("/api/refresh", refreshHandler(opts.DB, opts.JWTSecret))

	// WebSocket 日志流：浏览器无法自带 Authorization 头，改由 handler 内
	// 校验「Authorization 或一次性 ticket」。故该路由不放入鉴权组。
	r.GET("/api/servers/:id/containers/:cid/logs",
		containerLogsHandler(opts.DB, opts.MasterKey, opts.JWTSecret, opts.Pool))

	// 需鉴权端点
	authed := r.Group("/api", JWTAuth(opts.JWTSecret, opts.DB), AuditMiddleware(opts.DB))
	authed.GET("/me", meHandler(opts.DB))
	authed.GET("/audit", listAuditHandler(opts.DB))

	// 首屏聚合（M9.0b）：服务器列表 + 各机最新指标 + 未读告警 + 版本/schema/ver
	authed.GET("/bootstrap", bootstrapHandler(opts))

	// 服务器管理
	authed.GET("/servers", listServersHandler(opts.DB))
	authed.POST("/servers", createServerHandler(opts.DB, opts.MasterKey))
	authed.GET("/servers/:id", getServerHandler(opts.DB))
	authed.DELETE("/servers/:id", deleteServerHandler(opts.DB))
	authed.POST("/servers/:id/test", testServerHandler(opts.DB, opts.MasterKey, opts.Pool))

	// Docker 管理
	authed.GET("/servers/:id/containers", listContainersHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.POST("/servers/:id/containers/:cid/actions", containerActionHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.POST("/servers/:id/containers/:cid/logs-ticket", logsTicketHandler(opts.JWTSecret))
	authed.GET("/servers/:id/images", listImagesHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.POST("/servers/:id/images/pull", pullImageHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.DELETE("/servers/:id/images/:imageId", removeImageHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.GET("/servers/:id/networks", listNetworksHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.GET("/servers/:id/volumes", listVolumesHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.GET("/servers/:id/container-stats", containerStatsHandler(opts.DB, opts.MasterKey, opts.Pool))

	// 设置面（M8.1b/M8.1c）
	authed.GET("/settings", getSettingsHandler(opts.Settings, opts.MasterKey, opts.Port))
	authed.PUT("/settings", putSettingsHandler(opts.Settings, opts.MasterKey, opts.Port))
	authed.POST("/settings/test-channel", testChannelHandler(opts.Settings))
	authed.POST("/settings/actions/revoke-sessions", revokeSessionsHandler(opts.DB))
	authed.POST("/auth/change-password", changePasswordHandler(opts.DB, opts.JWTSecret))
	authed.POST("/auth/change-username", changeUsernameHandler(opts.DB))

	// 监控
	authed.GET("/servers/:id/metrics", metricsHandler(opts.DB))
	authed.GET("/servers/:id/metrics/latest", latestMetricHandler(opts.DB))

	// 告警规则
	authed.GET("/alert-rules", listAlertRulesHandler(opts.DB))
	authed.POST("/alert-rules", createAlertRuleHandler(opts.DB))
	authed.PUT("/alert-rules/:id", updateAlertRuleHandler(opts.DB))
	authed.DELETE("/alert-rules/:id", deleteAlertRuleHandler(opts.DB))

	// 通知中心
	authed.GET("/alerts", listAlertsHandler(opts.DB))
	authed.POST("/alerts/:id/read", markAlertReadHandler(opts.DB))

	// 文件管理
	authed.GET("/servers/:id/files", listFilesHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.GET("/servers/:id/files/download", downloadFileHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.POST("/servers/:id/files/upload", uploadFileHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.GET("/servers/:id/files/content", getContentHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.PUT("/servers/:id/files/content", putContentHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.POST("/servers/:id/files/rename", renameFileHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.POST("/servers/:id/files/copy", copyFileHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.DELETE("/servers/:id/files", deleteFileHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.GET("/servers/:id/files/stat", statFileHandler(opts.DB, opts.MasterKey, opts.Pool))

	// Compose 配置管理
	// compose.roots 白名单每请求解析：settings 有值用 settings（热生效），否则回落启动配置
	composeRoots := func() []string {
		if opts.Settings != nil {
			if v := strings.TrimSpace(opts.Settings.GetOr("compose.roots", "")); v != "" {
				return strings.Split(v, ",")
			}
		}
		return opts.ComposeRoots
	}
	authed.GET("/servers/:id/compose", listComposeHandler(opts.DB, opts.MasterKey, opts.Pool, composeRoots))
	authed.GET("/servers/:id/compose/content", getComposeContentHandler(opts.DB, opts.MasterKey, opts.Pool, composeRoots))
	authed.PUT("/servers/:id/compose/content", putComposeContentHandler(opts.DB, opts.MasterKey, opts.Pool, composeRoots))
	authed.POST("/servers/:id/compose/actions", composeActionHandler(opts.DB, opts.MasterKey, opts.Pool, composeRoots))

	// 后台任务（M9.0b）：查询 / 取消软件包升级等异步任务
	authed.GET("/jobs/:id", jobGetHandler())
	authed.DELETE("/jobs/:id", jobDeleteHandler())

	// 软件包更新（SSE 流式 + 202 双通道，M9.0b）
	authed.POST("/servers/:id/packages/update", packageUpdateHandler(opts.DB, opts.MasterKey, opts.Pool))

	// 前端静态资源（web/dist），SPA 回退；目录缺失时静默跳过
	registerWebStatic(r, opts.WebDir)

	return r
}
