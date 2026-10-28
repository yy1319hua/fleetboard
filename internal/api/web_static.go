package api

import (
	"io/fs"
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
)

// suicideSW 是「自杀 Service Worker」：PWA 已剥离（v2 裁决）后，装过 v0.1.x PWA 的
// 老浏览器仍被旧 SW 劫持（旧页面永远加载不到新反注册代码）。此响应会让浏览器把
// 旧 SW 替换为本 SW，随即注销自身并清缓存——老设备下次访问即自动解除劫持。
const suicideSW = `self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    for (const k of keys) await caches.delete(k);
    await self.registration.unregister();
    const cs = await self.clients.matchAll({ type: "window" });
    for (const c of cs) c.navigate(c.url);
  })());
});`

// registerWebStatic 把构建好的前端（web/dist）挂到路由上：
// - 命中真实文件 → 直接返回（带 Cache-Control：hashed 资源长缓存）
// - 未命中 → 回退 index.html（SPA 前端路由）
// - /api/* 不回退，保持 JSON 404，避免前端路由吃掉接口错误
// - /sw.js 恒返回自杀 SW（no-cache），救回所有装过旧 PWA 的老端
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
		if p == "/sw.js" {
			c.Header("Cache-Control", "no-cache")
			c.Data(http.StatusOK, "application/javascript; charset=utf-8", []byte(suicideSW))
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
			c.Header("Cache-Control", "no-cache")
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
