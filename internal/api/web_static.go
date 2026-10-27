package api

import (
	"io/fs"
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
)

// registerWebStatic 把构建好的前端（web/dist）挂到路由上：
// - 命中真实文件 → 直接返回（带 Cache-Control：hashed 资源长缓存）
// - 未命中 → 回退 index.html（SPA 前端路由）
// - /api/* 不回退，保持 JSON 404，避免前端路由吃掉接口错误
//
// 目录不存在（如纯 API 部署）时静默跳过，不影响启动。
func registerWebStatic(r *gin.Engine, dir string) {
	if dir == "" {
		return
	}
	root, err := fs.Sub(os.DirFS(dir), ".")
	if err != nil {
		return
	}
	if _, err := fs.Stat(root, "index.html"); err != nil {
		return // dist 不存在或缺 index.html，跳过
	}
	fileServer := http.StripPrefix("/", http.FileServer(http.FS(root)))
	r.NoRoute(func(c *gin.Context) {
		p := c.Request.URL.Path
		if strings.HasPrefix(p, "/api/") {
			Fail(c, ErrNotFound("接口不存在"))
			return
		}
		// 探测文件是否存在；不存在则回退 index.html
		rel := strings.TrimPrefix(p, "/")
		if rel == "" {
			rel = "index.html"
		}
		if _, err := fs.Stat(root, rel); err != nil {
			data, rErr := fs.ReadFile(root, "index.html")
			if rErr != nil {
				c.String(http.StatusNotFound, "frontend not built")
				return
			}
			c.Data(http.StatusOK, "text/html; charset=utf-8", data)
			return
		}
		if strings.HasPrefix(rel, "assets/") {
			c.Header("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			c.Header("Cache-Control", "no-cache")
		}
		fileServer.ServeHTTP(c.Writer, c.Request)
	})
}
