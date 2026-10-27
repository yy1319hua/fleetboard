package api

import (
	"database/sql"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/db"
)

const ctxUserID = "uid"

// JWTAuth 校验 Authorization: Bearer <access>，通过后把用户 ID 注入上下文。
func JWTAuth(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.GetHeader("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			Fail(c, ErrUnauthorized("缺少访问令牌"))
			c.Abort()
			return
		}
		tokenStr := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
		claims, err := auth.ParseAccessToken(secret, tokenStr)
		if err != nil {
			Fail(c, ErrUnauthorized("访问令牌无效或已过期"))
			c.Abort()
			return
		}
		c.Set(ctxUserID, claims.UserID)
		c.Next()
	}
}

// CurrentUserID 返回上下文中的用户 ID；未认证时为 0。
func CurrentUserID(c *gin.Context) int64 {
	v, ok := c.Get(ctxUserID)
	if !ok {
		return 0
	}
	id, _ := v.(int64)
	return id
}

// AuditMiddleware 在请求完成后记录操作审计（须置于 JWTAuth 之后）。
func AuditMiddleware(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()

		uid := CurrentUserID(c)
		if uid == 0 {
			return
		}
		action := c.Request.Method + " " + c.FullPath()
		result := "ok"
		if c.Writer.Status() >= 400 {
			result = "fail"
		}
		_ = db.InsertAudit(d, uid, nil, action, c.Request.URL.Path, result)
	}
}
