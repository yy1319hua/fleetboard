package api

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
)

type createServerRequest struct {
	Name       string `json:"name" binding:"required"`
	Host       string `json:"host" binding:"required"`
	Port       int    `json:"port"`
	SSHUser    string `json:"ssh_user"`
	AuthMethod string `json:"auth_method"`
	Password   string `json:"password"`
	PrivateKey string `json:"private_key"`
	KeyPass    string `json:"key_pass"`
	Tags       string `json:"tags"`
}

// createServerHandler 注册服务器；凭据加密后落库，响应不含凭据。
func createServerHandler(d *sql.DB, masterKey string) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req createServerRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("name 与 host 不能为空"))
			return
		}
		s, err := db.CreateServer(d, masterKey, db.CreateServerInput{
			Name:       req.Name,
			Host:       req.Host,
			Port:       req.Port,
			SSHUser:    req.SSHUser,
			AuthMethod: req.AuthMethod,
			Password:   req.Password,
			PrivateKey: req.PrivateKey,
			KeyPass:    req.KeyPass,
			Tags:       req.Tags,
		})
		if err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		c.JSON(201, Response{Code: CodeOK, Msg: "ok", Data: s})
	}
}

// listServersHandler 返回全部服务器（不含凭据）。
func listServersHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		list, err := db.ListServers(d)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, list)
	}
}

// getServerHandler 返回服务器详情。
func getServerHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		s, err := db.GetServer(d, id)
		if errors.Is(err, db.ErrServerNotFound) {
			Fail(c, ErrNotFound("服务器不存在"))
			return
		}
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, s)
	}
}

// deleteServerHandler 删除服务器（凭据级联删除）。
func deleteServerHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		err := db.DeleteServer(d, id)
		if errors.Is(err, db.ErrServerNotFound) {
			Fail(c, ErrNotFound("服务器不存在"))
			return
		}
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"deleted": id})
	}
}

// testServerHandler 尝试建立 SSH 连接，更新并返回连接状态。
func testServerHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}

		s, err := db.GetServer(d, id)
		if errors.Is(err, db.ErrServerNotFound) {
			Fail(c, ErrNotFound("服务器不存在"))
			return
		}
		if err != nil {
			Fail(c, err)
			return
		}

		cred, err := db.GetDecryptedCredential(d, masterKey, id)
		if err != nil {
			Fail(c, err)
			return
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), 10*time.Second)
		defer cancel()

		_, connErr := pool.Get(ctx, id, sshpool.Config{
			Host:       s.Host,
			Port:       s.Port,
			User:       s.SSHUser,
			AuthMethod: cred.AuthMethod,
			Password:   cred.Password,
			PrivateKey: cred.PrivateKey,
			KeyPass:    cred.KeyPass,
		})

		status := "online"
		if connErr != nil {
			status = "offline"
		}
		_ = db.UpdateServerStatus(d, id, status)

		if connErr != nil {
			Fail(c, ErrBadGateway("连接失败: "+connErr.Error()))
			return
		}
		OK(c, gin.H{"server_id": id, "status": status})
	}
}

// updateServerRequest 是 PUT /api/servers/{id} 的请求体。
//
// 凭据三字段留空 = 保持原值（改端口/改名不必重贴私钥）；
// auth_method 留空 = 沿用原认证方式。
type updateServerRequest struct {
	Name       string `json:"name" binding:"required"`
	Host       string `json:"host" binding:"required"`
	Port       int    `json:"port"`
	SSHUser    string `json:"ssh_user"`
	AuthMethod string `json:"auth_method"`
	Password   string `json:"password"`
	PrivateKey string `json:"private_key"`
	KeyPass    string `json:"key_pass"`
	Tags       string `json:"tags"`
}

// updateServerHandler 更新服务器；成功后关闭旧连接、状态置 unknown。
//
// 置 unknown 而不是沿用 online：地址/凭据可能已变，旧状态不再可信；
// 新一轮采集或用户点「测试连接」会给出真实结果。
func updateServerHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		var req updateServerRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("name 与 host 不能为空"))
			return
		}
		s, err := db.UpdateServer(d, masterKey, id, db.UpdateServerInput{
			Name:       req.Name,
			Host:       req.Host,
			Port:       req.Port,
			SSHUser:    req.SSHUser,
			AuthMethod: req.AuthMethod,
			Password:   req.Password,
			PrivateKey: req.PrivateKey,
			KeyPass:    req.KeyPass,
			Tags:       req.Tags,
		})
		if errors.Is(err, db.ErrServerNotFound) {
			Fail(c, ErrNotFound("服务器不存在"))
			return
		}
		if err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}
		if pool != nil {
			pool.Close(id)
		}
		_ = db.MarkServerUnknown(d, id)
		if s != nil {
			s.ConnectionStatus = "unknown"
		}
		OK(c, s)
	}
}

// probeServerRequest 是 POST /api/servers/probe 的请求体。
//
// ServerID 可选：编辑场景下允许只传要改的字段，凭据留空时用库里已存的补齐。
type probeServerRequest struct {
	Host       string `json:"host"`
	Port       int    `json:"port"`
	SSHUser    string `json:"ssh_user"`
	AuthMethod string `json:"auth_method"`
	Password   string `json:"password"`
	PrivateKey string `json:"private_key"`
	KeyPass    string `json:"key_pass"`
	ServerID   int64  `json:"server_id"`
}

// probeServerHandler 用给定参数试连一次 SSH，**不落库**。
//
// 这是纳管流程从「先建后测」翻转为「先测后存」的关键：连不上就什么都不留下，
// 列表里不会出现一台永远连不上的机器，监控循环也不会为它反复告警。
func probeServerHandler(d *sql.DB, masterKey string, pool *sshpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req probeServerRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("请求格式非法"))
			return
		}

		host := req.Host
		port := req.Port
		user := req.SSHUser
		auth := req.AuthMethod
		password, privateKey, keyPass := req.Password, req.PrivateKey, req.KeyPass

		// 编辑场景：库里已有记录时，缺省字段用记录补齐（凭据留空不改）。
		if req.ServerID > 0 {
			s, err := db.GetServer(d, req.ServerID)
			if errors.Is(err, db.ErrServerNotFound) {
				Fail(c, ErrNotFound("服务器不存在"))
				return
			}
			if err != nil {
				Fail(c, err)
				return
			}
			cred, err := db.GetDecryptedCredential(d, masterKey, req.ServerID)
			if err != nil {
				Fail(c, err)
				return
			}
			if host == "" {
				host = s.Host
			}
			if port == 0 {
				port = s.Port
			}
			if user == "" {
				user = s.SSHUser
			}
			if auth == "" {
				auth = cred.AuthMethod
			}
			if password == "" && auth == "password" {
				password = cred.Password
			}
			if privateKey == "" && auth == "key" {
				privateKey = cred.PrivateKey
				if keyPass == "" {
					keyPass = cred.KeyPass
				}
			}
		}

		if host == "" {
			Fail(c, ErrBadRequest("host 不能为空"))
			return
		}
		if port != 0 && (port < 1 || port > 65535) {
			Fail(c, ErrBadRequest("端口需在 1–65535 之间"))
			return
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), 10*time.Second)
		defer cancel()

		elapsed, connErr := pool.Probe(ctx, sshpool.Config{
			Host:       host,
			Port:       port,
			User:       user,
			AuthMethod: auth,
			Password:   password,
			PrivateKey: privateKey,
			KeyPass:    keyPass,
		})
		if connErr != nil {
			Fail(c, ErrBadGateway("连接失败: "+connErr.Error()))
			return
		}
		OK(c, gin.H{"ok": true, "elapsed_ms": elapsed.Milliseconds()})
	}
}

// parseID 解析路径参数 :id；失败时已写入错误响应，返回 ok=false。
func parseID(c *gin.Context) (int64, bool) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		Fail(c, ErrBadRequest("id 非法"))
		return 0, false
	}
	return id, true
}
