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
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/pkg/sftp"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/file"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"golang.org/x/crypto/ssh"
)

// openSSH 建立到被管机的 SSH 连接（来自连接池）。
func openSSH(c *gin.Context, d *sql.DB, masterKey string, pool *sshpool.Pool, id int64) (*ssh.Client, error) {
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
	return cli, nil
}

// sftpHandshakeTimeout 是 subsystem 请求发出后等待服务端 VERSION 的上限。
//
// 正常主机在一秒内回包；超时说明对端收下请求却不启动 sftp-server，
// 典型场景是虚拟主机限制了并发 SSH 连接。
const sftpHandshakeTimeout = 6 * time.Second

type sftpResult struct {
	client *sftp.Client
	err    error
}

// openSFTP 建立到被管机的 SFTP 会话；调用方负责 Close。
//
// sftp.NewClient 内部的 recvVersion 是阻塞读、没有超时，服务端不回 VERSION
// 就会永久挂住。这里用协程 + select 兜底：超时后关闭整条 SSH 连接，让那个
// 协程收到 EOF 自行退出，并把它从池里摘掉，避免半死连接被后续请求复用。
func openSFTP(c *gin.Context, d *sql.DB, masterKey string, pool *sshpool.Pool, id int64) (*sftp.Client, error) {
	cli, err := openSSH(c, d, masterKey, pool, id)
	if err != nil {
		return nil, err
	}

	// 带缓冲：超时分支返回后协程仍会写一次，缓冲区保证它不会卡在发送上泄漏。
	done := make(chan sftpResult, 1)
	go func() {
		sc, err := sftp.NewClient(cli)
		done <- sftpResult{client: sc, err: err}
	}()

	select {
	case r := <-done:
		if r.err != nil {
			_ = cli.Close()
			pool.Close(id)
			return nil, ErrBadGateway("SFTP 会话失败: " + r.err.Error())
		}
		return r.client, nil
	case <-time.After(sftpHandshakeTimeout):
		_ = cli.Close()
		pool.Close(id)
		return nil, ErrBadGateway("SFTP 会话超时：主机接受了连接但未响应 sftp 子系统，常见于限制并发 SSH 连接的主机")
	}
}

// fileErr 把 SFTP 的原始错误翻译成可操作的 HTTP 状态与文案。
//
// 过去一律报 502「读取目录失败: remote readdir("/"): Permission denied」：
// 状态码指向「网关坏了」，文案是英文原文，用户既看不出是权限问题，也不知道该去哪。
func fileErr(action string, err error) *APIError {
	msg := err.Error()
	low := strings.ToLower(msg)
	switch {
	case strings.Contains(low, "permission denied"):
		return ErrForbidden(action + "失败：该目录不允许访问（远程返回 permission denied）")
	case strings.Contains(low, "no such file"), strings.Contains(low, "not exist"):
		return ErrNotFound(action + "失败：路径不存在")
	case strings.Contains(low, "not a directory"):
		return ErrBadRequest(action + "失败：目标不是目录")
	default:
		return ErrBadGateway(action + "失败: " + msg)
	}
}

// listFilesHandler 目录列表（排序 + 分页）。
//
// GET /api/servers/:id/files?path=/&sort=name&order=asc&offset=0&limit=200
//
// path 省略时返回「登录目录」（sftp 的 Getwd，通常即用户家目录），并在响应里
// 回传实际使用的 path 与 home：一部分主机（serv00 这类 FreeBSD 虚拟主机）
// 普通账户读不了 /，前端硬编码从根开始会直接 permission denied。
func listFilesHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		dir := c.Query("path")
		if dir != "" {
			if err := file.ValidatePath(dir); err != nil {
				Fail(c, ErrBadRequest(err.Error()))
				return
			}
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		// home 取不到不影响列表：只作为前端「回到我的目录」的落点。
		home, err := sc.Getwd()
		if err != nil {
			home = ""
		}
		if dir == "" {
			dir = home
			if dir == "" {
				dir = "/" // 服务端不报登录目录时的兜底
			}
		}

		entries, err := file.List(sc, dir)
		if err != nil {
			Fail(c, fileErr("读取目录", err))
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
			"path":    dir,
			"home":    home,
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
		if err := file.ValidatePath(p); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
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
			Fail(c, fileErr("打开文件", err))
			return
		}
		defer func() { _ = f.Close() }()

		fi, err := f.Stat()
		if err != nil {
			Fail(c, fileErr("读取文件信息", err))
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
		if err := file.ValidatePath(p); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
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
			Fail(c, fileErr("打开文件写入", err))
			return
		}
		defer func() { _ = f.Close() }()

		n, err := io.Copy(f, c.Request.Body)
		if err != nil {
			Fail(c, fileErr("写入", err))
			return
		}

		OK(c, gin.H{"path": p, "offset": offset, "written": n})
	}
}

// maxTextBytes 在线编辑的文本大小上限（1 MiB）。
const maxTextBytes = 1 << 20

type fileContentResponse struct {
	Path    string `json:"path"`
	Content string `json:"content"`
	Size    int    `json:"size"`
}

// getContentHandler 读取文本内容（用于在线编辑）。
// GET /api/servers/:id/files/content?path=/x
func getContentHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		p := c.Query("path")
		if err := file.ValidatePath(p); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
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

		content, err := file.ReadText(sc, p, maxTextBytes)
		if err != nil {
			Fail(c, fileErr("读取文件", err))
			return
		}
		OK(c, fileContentResponse{Path: p, Content: content, Size: len(content)})
	}
}

type putContentRequest struct {
	Content string `json:"content"`
}

// putContentHandler 原子写入文本内容（保留权限属主）。
// PUT /api/servers/:id/files/content?path=/x  body: {"content":"..."}
func putContentHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		p := c.Query("path")
		if err := file.ValidatePath(p); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		if p == "" {
			Fail(c, ErrBadRequest("path 不能为空"))
			return
		}

		var req putContentRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需为 {"content":"..."}`))
			return
		}
		if len(req.Content) > maxTextBytes {
			Fail(c, ErrBadRequest("内容超过 1MiB 上限"))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		if err := file.WriteAtomic(sc, p, req.Content); err != nil {
			Fail(c, fileErr("写入", err))
			return
		}
		OK(c, gin.H{"path": p, "size": len(req.Content)})
	}
}

type filePairRequest struct {
	From string `json:"from" binding:"required"`
	To   string `json:"to" binding:"required"`
}

// renameFileHandler 重命名/移动。
// POST /api/servers/:id/files/rename  body: {"from":"...","to":"..."}
func renameFileHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		var req filePairRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需为 {"from":"...","to":"..."}`))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		if err := file.ValidatePath(req.From); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		if err := file.ValidatePath(req.To); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		if err := file.Rename(sc, req.From, req.To); err != nil {
			Fail(c, fileErr("重命名", err))
			return
		}
		OK(c, gin.H{"from": req.From, "to": req.To})
	}
}

// copyFileHandler 复制文件/目录。
// POST /api/servers/:id/files/copy  body: {"from":"...","to":"..."}
func copyFileHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		var req filePairRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需为 {"from":"...","to":"..."}`))
			return
		}

		sc, err := openSFTP(c, d, masterKey, pool, id)
		if err != nil {
			Fail(c, err)
			return
		}
		defer func() { _ = sc.Close() }()

		if err := file.ValidatePath(req.From); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		if err := file.ValidatePath(req.To); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		if err := file.Copy(sc, req.From, req.To); err != nil {
			Fail(c, fileErr("复制", err))
			return
		}
		OK(c, gin.H{"from": req.From, "to": req.To})
	}
}

// deleteFileHandler 删除文件/目录（目录递归）。
// DELETE /api/servers/:id/files?path=/x
func deleteFileHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		p := c.Query("path")
		if err := file.ValidatePath(p); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
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

		if err := file.Remove(sc, p); err != nil {
			Fail(c, fileErr("删除", err))
			return
		}
		OK(c, gin.H{"deleted": p})
	}
}

// statFileHandler 查看权限与属主。
// GET /api/servers/:id/files/stat?path=/x
func statFileHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		p := c.Query("path")
		if err := file.ValidatePath(p); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
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

		e, err := file.Stat(sc, p)
		if err != nil {
			Fail(c, fileErr("读取文件信息", err))
			return
		}
		OK(c, e)
	}
}
