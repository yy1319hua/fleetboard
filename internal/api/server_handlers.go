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

// parseID 解析路径参数 :id；失败时已写入错误响应，返回 ok=false。
func parseID(c *gin.Context) (int64, bool) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		Fail(c, ErrBadRequest("id 非法"))
		return 0, false
	}
	return id, true
}
