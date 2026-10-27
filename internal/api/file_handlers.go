package api

import (
	"context"
	"database/sql"
	"errors"
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
