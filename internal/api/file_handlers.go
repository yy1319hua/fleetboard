package api

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/pkg/sftp"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/file"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

// openSFTP 建立到被管机的 SFTP 会话；调用方负责 Close。
func openSFTP(c *gin.Context, d *sql.DB, masterKey string, pool *sshpool.Pool, id int64) (*sftp.Client, error) {
	s, err := db.GetServer(d, id)
	if errors.Is(err, db.ErrServerNotFound) {
		return nil, ErrNotFound("服务器不存在")
	}
	if err != nil {
		return nil, err
	}

	cred, err := db.GetDecryptedCredential(d, masterKey, id)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
	defer cancel()

	cli, err := pool.Get(ctx, id, sshpool.Config{
		Host:       s.Host,
		Port:       s.Port,
		User:       s.SSHUser,
		AuthMethod: cred.AuthMethod,
		Password:   cred.Password,
		PrivateKey: cred.PrivateKey,
		KeyPass:    cred.KeyPass,
	})
	if err != nil {
		return nil, ErrBadGateway("SSH 连接失败: " + err.Error())
	}

	sc, err := sftp.NewClient(cli)
	if err != nil {
		return nil, ErrBadGateway("SFTP 会话失败: " + err.Error())
	}
	return sc, nil
}

// listFilesHandler 目录列表（排序 + 分页）。
// GET /api/servers/:id/files?path=/&sort=name&order=asc&offset=0&limit=200
func listFilesHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		dir := c.DefaultQuery("path", "/")

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		entries, err := file.List(sc, dir)
		if err != nil {
			Fail(c, ErrBadGateway("读取目录失败: "+err.Error()))
			return
		}

		file.SortEntries(entries, c.Query("sort"), c.Query("order"))
		total := len(entries)

		offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
		limit, _ := strconv.Atoi(c.DefaultQuery("limit", "200"))
		page := file.Paginate(entries, offset, limit)

		OK(c, gin.H{
			"entries": page,
			"total":   total,
			"offset":  offset,
			"limit":   limit,
		})
	}
}

// downloadFileHandler 文件下载，支持 HTTP Range（断点/分段）。
// GET /api/servers/:id/files/download?path=/x
func downloadFileHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		p := c.Query("path")
		if p == "" {
			Fail(c, ErrBadRequest("path 不能为空"))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		f, err := file.Open(sc, p)
		if err != nil {
			Fail(c, ErrBadGateway("打开文件失败: "+err.Error()))
			return
		}
		defer func() { _ = f.Close() }()

		fi, err := f.Stat()
		if err != nil {
			Fail(c, ErrBadGateway("读取文件信息失败: "+err.Error()))
			return
		}

		c.Header("Content-Type", "application/octet-stream")
		c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%q", path.Base(p)))
		// ServeContent 自动处理 Range / If-Modified-Since / Content-Length
		http.ServeContent(c.Writer, c.Request, path.Base(p), fi.ModTime(), f)
	}
}

// uploadFileHandler 文件上传；offset>0 表示断点续传/分片续写。
// POST /api/servers/:id/files/upload?path=/x&offset=0，body 为原始字节
func uploadFileHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		p := c.Query("path")
		if p == "" {
			Fail(c, ErrBadRequest("path 不能为空"))
			return
		}

		offset, err := strconv.ParseInt(c.DefaultQuery("offset", "0"), 10, 64)
		if err != nil || offset < 0 {
			Fail(c, ErrBadRequest("offset 非法"))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		f, err := file.OpenWrite(sc, p, offset)
		if err != nil {
			Fail(c, ErrBadGateway("打开文件写入失败: "+err.Error()))
			return
		}
		defer func() { _ = f.Close() }()

		n, err := io.Copy(f, c.Request.Body)
		if err != nil {
			Fail(c, ErrBadGateway("写入失败: "+err.Error()))
			return
		}

		OK(c, gin.H{"path": p, "offset": offset, "written": n})
	}
}
