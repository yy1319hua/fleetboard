package api

import (
	"database/sql"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// RouterOptions 是构建路由所需的运行期信息。
type RouterOptions struct {
	Version   string // 服务版本
	Schema    string // 当前数据库迁移版本
	DB        *sql.DB
	JWTSecret string
	MasterKey string // 凭据加密主密钥（KEY）
	Pool      *sshpool.Pool
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
		OK(c, gin.H{
			"status":  "ok",
			"version": opts.Version,
			"schema":  opts.Schema,
		})
	})
	r.POST("/api/login", loginHandler(opts.DB, opts.JWTSecret))
	r.POST("/api/refresh", refreshHandler(opts.JWTSecret))

	// 需鉴权端点
	authed := r.Group("/api", JWTAuth(opts.JWTSecret), AuditMiddleware(opts.DB))
	authed.GET("/me", meHandler())
	authed.GET("/audit", listAuditHandler(opts.DB))

	// 服务器管理
	authed.GET("/servers", listServersHandler(opts.DB))
	authed.POST("/servers", createServerHandler(opts.DB, opts.MasterKey))
	authed.GET("/servers/:id", getServerHandler(opts.DB))
	authed.DELETE("/servers/:id", deleteServerHandler(opts.DB))
	authed.POST("/servers/:id/test", testServerHandler(opts.DB, opts.MasterKey, opts.Pool))

	// 文件管理
	authed.GET("/servers/:id/files", listFilesHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.GET("/servers/:id/files/download", downloadFileHandler(opts.DB, opts.MasterKey, opts.Pool))
	authed.POST("/servers/:id/files/upload", uploadFileHandler(opts.DB, opts.MasterKey, opts.Pool))

	return r
}
