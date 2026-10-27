package api

import (
	"database/sql"
	"errors"
	"path"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/compose"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// firstComposeRoot 返回白名单首个根目录，作为列目录的默认起点。
func firstComposeRoot(roots []string) string {
	rs := compose.NormalizeRoots(roots)
	if len(rs) == 0 {
		return "/root"
	}
	return rs[0]
}

// listComposeHandler 列出指定目录下的 compose 文件（含可下钻子目录）。
func listComposeHandler(d *sql.DB, masterKey string, pool *sshpool.Pool, roots []string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		dir := c.DefaultQuery("dir", firstComposeRoot(roots))
		if err := compose.ValidatePath(dir, roots); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		res, err := compose.ListFiles(sc, dir, roots)
		if err != nil {
			if errors.Is(err, compose.ErrPathDenied) {
				Fail(c, ErrBadRequest(err.Error()))
				return
			}
			Fail(c, ErrBadGateway("列目录失败: "+err.Error()))
			return
		}

		OK(c, gin.H{
			"roots":   compose.NormalizeRoots(roots),
			"dir":     res.Dir,
			"dirs":    res.Dirs,
			"files":   res.Files,
			"skipped": res.Skipped,
		})
	}
}

// getComposeContentHandler 读取 compose 文件内容（仅文本，限制 2MiB）。
func getComposeContentHandler(d *sql.DB, masterKey string, pool *sshpool.Pool, roots []string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		p := c.Query("path")
		if p == "" {
			Fail(c, ErrBadRequest("缺少 path 参数"))
			return
		}
		if err := compose.ValidatePath(p, roots); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		content, err := compose.Read(sc, p, roots)
		if err != nil {
			Fail(c, ErrBadGateway("读取 compose 文件失败: "+err.Error()))
			return
		}

		OK(c, gin.H{
			"path":    path.Clean(p),
			"content": content,
			"size":    len(content),
		})
	}
}

// putComposeContentHandler 保存 compose 文件（原子写：临时文件 + rename，保留权限属主）。
func putComposeContentHandler(d *sql.DB, masterKey string, pool *sshpool.Pool, roots []string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		var req struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		}
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("请求体非法"))
			return
		}
		if req.Path == "" {
			Fail(c, ErrBadRequest("缺少 path"))
			return
		}
		if err := compose.ValidatePath(req.Path, roots); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		if strings.TrimSpace(req.Content) == "" {
			Fail(c, ErrBadRequest("内容为空，拒绝写入"))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		if err := compose.Write(sc, req.Path, req.Content, roots); err != nil {
			if errors.Is(err, compose.ErrPathDenied) {
				Fail(c, ErrBadRequest(err.Error()))
				return
			}
			Fail(c, ErrBadGateway("保存 compose 文件失败: "+err.Error()))
			return
		}

		OK(c, gin.H{"path": path.Clean(req.Path), "size": len(req.Content)})
	}
}
