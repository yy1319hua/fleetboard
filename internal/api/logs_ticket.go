package api

import (
	"database/sql"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/docker"
)

// logsTicketHandler 为 WebSocket 日志流签发一次性短期票据。
// POST /api/servers/:id/containers/:cid/logs-ticket
//
// 浏览器 WebSocket 无法自带 Authorization 头，因此先用普通 HTTP（带 JWT）换一张
// 绑定「用户 + 服务器 + 容器」的 60 秒票据，再用 ?ticket= 建连。
// access token 绝不放进 URL。
func logsTicketHandler(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		id, ok := parseID(c)
		if !ok {
			return
		}
		cid := c.Param("cid")
		if err := docker.ValidateContainerID(cid); err != nil {
			Fail(c, ErrBadRequest(err.Error()))
			return
		}

		uid := CurrentUserID(c)
		ticket, err := auth.GenerateWSTicket(secret, uid, id, cid)
		if err != nil {
			Fail(c, err)
			return
		}

		OK(c, gin.H{
			"ticket":     ticket,
			"expires_in": int(auth.WSTicketTTL.Seconds()),
		})
	}
}

// authorizeWS 校验 WebSocket 请求身份：优先 Authorization 头，其次 ?ticket=。
// 票据必须与路径上的 serverID / cid 完全一致，避免票据被挪用到其他目标。
func authorizeWS(c *gin.Context, secret string, serverID int64, cid string) (int64, error) {
	if h := c.GetHeader("Authorization"); strings.HasPrefix(h, "Bearer ") {
		claims, err := auth.ParseAccessToken(secret, strings.TrimSpace(strings.TrimPrefix(h, "Bearer ")))
		if err != nil {
			return 0, ErrUnauthorized("访问令牌无效或已过期")
		}
		return claims.UserID, nil
	}

	ticket := c.Query("ticket")
	if ticket == "" {
		return 0, ErrUnauthorized("缺少访问凭证")
	}
	claims, err := auth.ParseWSTicket(secret, ticket)
	if err != nil {
		return 0, ErrUnauthorized("日志票据无效或已过期")
	}
	if claims.ServerID != serverID || claims.ContainerID != cid {
		return 0, ErrUnauthorized("日志票据与目标不匹配")
	}
	return claims.UserID, nil
}

// insertLogsAudit 记录一次日志流访问（WS 不走 AuditMiddleware，需显式写）。
func insertLogsAudit(d *sql.DB, uid, serverID int64, cid string) {
	if uid == 0 {
		return
	}
	sid := serverID
	_ = db.InsertAudit(d, uid, &sid, "containers.logs", cid, "ok")
}
