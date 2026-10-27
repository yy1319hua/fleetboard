package api

import (
	"database/sql"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/db"
)

type loginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token,omitempty"`
	ExpiresIn    int    `json:"expires_in"`
}

// loginHandler 用户名密码登录，返回 access + refresh。
func loginHandler(d *sql.DB, secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req loginRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("用户名和密码不能为空"))
			return
		}

		u, err := db.GetUserByUsername(d, req.Username)
		if err != nil {
			// 统一提示，避免用户名枚举
			Fail(c, ErrUnauthorized("用户名或密码错误"))
			return
		}
		if !auth.VerifyPassword(u.PasswordHash, req.Password) {
			Fail(c, ErrUnauthorized("用户名或密码错误"))
			return
		}

		access, err := auth.GenerateAccessToken(secret, u.ID)
		if err != nil {
			Fail(c, err)
			return
		}
		refresh, err := auth.GenerateRefreshToken(secret, u.ID)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, tokenResponse{
			AccessToken:  access,
			RefreshToken: refresh,
			ExpiresIn:    int(auth.AccessTTL.Seconds()),
		})
	}
}

// refreshHandler 用 refresh token 换新的 access token。
func refreshHandler(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		var req refreshRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("缺少 refresh_token"))
			return
		}
		claims, err := auth.ParseRefreshToken(secret, req.RefreshToken)
		if err != nil {
			Fail(c, ErrUnauthorized("刷新令牌无效或已过期"))
			return
		}
		access, err := auth.GenerateAccessToken(secret, claims.UserID)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, tokenResponse{
			AccessToken: access,
			ExpiresIn:   int(auth.AccessTTL.Seconds()),
		})
	}
}

// meHandler 返回当前登录用户 ID（最小可用，用于验证鉴权链路）。
func meHandler() gin.HandlerFunc {
	return func(c *gin.Context) {
		uid := CurrentUserID(c)
		if uid == 0 {
			Fail(c, ErrUnauthorized("未认证"))
			return
		}
		OK(c, gin.H{"id": uid})
	}
}
