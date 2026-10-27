package api

import (
	"os"

	"github.com/gin-gonic/gin"
)

// RouterOptions 是构建路由所需的运行期信息。
type RouterOptions struct {
	Version string // 服务版本
	Schema  string // 当前数据库迁移版本
}

// NewRouter 构建 HTTP 路由。
func NewRouter(opts RouterOptions) *gin.Engine {
	// 未显式指定 GIN_MODE 时默认 release，避免生产打印 debug 路由信息。
	if os.Getenv("GIN_MODE") == "" && gin.Mode() == gin.DebugMode {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())

	r.GET("/api/health", func(c *gin.Context) {
		OK(c, gin.H{
			"status":  "ok",
			"version": opts.Version,
			"schema":  opts.Schema,
		})
	})

	return r
}
