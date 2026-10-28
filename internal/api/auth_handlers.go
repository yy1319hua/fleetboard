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

		access, err := auth.GenerateAccessToken(secret, u.ID, u.TokenVer)
		if err != nil {
			Fail(c, err)
			return
		}
		refresh, err := auth.GenerateRefreshToken(secret, u.ID, u.TokenVer)
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
func refreshHandler(d *sql.DB, secret string) gin.HandlerFunc {
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
		// M8.1e：ver epoch 校验——改密/注销后旧 refresh 即便未过期也吊销
		ver, err := db.GetTokenVer(d, claims.UserID)
		if err != nil || ver != claims.Ver {
			Fail(c, ErrUnauthorized("刷新令牌无效或已过期"))
			return
		}
		access, err := auth.GenerateAccessToken(secret, claims.UserID, ver)
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

type changePasswordRequest struct {
	OldPassword string `json:"old_password" binding:"required"`
	NewPassword string `json:"new_password" binding:"required"`
}

// changePasswordHandler 修改密码（M8.1e）：验旧密 → 更新哈希 + ver 自增（同事务）。
// ver 自增使所有旧 access/refresh（含其他端的 7 天 refresh）立即失效；
// 当前会话返回新 token 对，无感续期。
func changePasswordHandler(d *sql.DB, secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		uid := CurrentUserID(c)
		if uid == 0 {
			Fail(c, ErrUnauthorized("未认证"))
			return
		}
		var req changePasswordRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("旧密码与新密码不能为空"))
			return
		}
		if len(req.NewPassword) < 8 {
			Fail(c, ErrBadRequest("新密码至少 8 位"))
			return
		}
		u, err := db.GetUserByID(d, uid)
		if err != nil {
			Fail(c, ErrUnauthorized("用户不存在"))
			return
		}
		if !auth.VerifyPassword(u.PasswordHash, req.OldPassword) {
			Fail(c, ErrUnauthorized("旧密码错误"))
			return
		}
		hash, err := auth.HashPassword(req.NewPassword)
		if err != nil {
			Fail(c, err)
			return
		}
		ver, err := db.UpdatePasswordAndBumpVer(d, uid, hash)
		if err != nil {
			Fail(c, err)
			return
		}
		access, err := auth.GenerateAccessToken(secret, uid, ver)
		if err != nil {
			Fail(c, err)
			return
		}
		refresh, err := auth.GenerateRefreshToken(secret, uid, ver)
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

// revokeSessionsHandler 注销所有会话（M8.1e）：ver 自增，本端与其他端全部下线，须重新登录。
func revokeSessionsHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		uid := CurrentUserID(c)
		if uid == 0 {
			Fail(c, ErrUnauthorized("未认证"))
			return
		}
		if _, err := db.BumpTokenVer(d, uid); err != nil {
			Fail(c, err)
			return
		}
		OK(c, gin.H{"revoked": true})
	}
}
