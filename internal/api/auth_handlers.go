package api

import (
	"database/sql"
	"errors"
	"regexp"
	"time"

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
	AccessToken      string `json:"access_token"`
	RefreshToken     string `json:"refresh_token,omitempty"`
	ExpiresIn        int    `json:"expires_in"`
	RefreshExpiresAt int64  `json:"refresh_expires_at,omitempty"` // M9.0b：派生自 refresh token 既有 ExpiresAt，向后兼容（omitempty）
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
			AccessToken:      access,
			RefreshToken:     refresh,
			ExpiresIn:        int(auth.AccessTTL.Seconds()),
			RefreshExpiresAt: time.Now().Add(auth.RefreshTTL).Unix(),
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
			Fail(c, ErrUnauthorized("token revoked"))
			return
		}
		access, err := auth.GenerateAccessToken(secret, claims.UserID, ver)
		if err != nil {
			Fail(c, err)
			return
		}
		OK(c, tokenResponse{
			AccessToken:      access,
			ExpiresIn:        int(auth.AccessTTL.Seconds()),
			RefreshExpiresAt: claims.ExpiresAt.Unix(),
		})
	}
}

// meHandler 返回当前登录用户的身份信息。
//
// M11 补 username：改名之后客户端需要刷新显示名，而 JWT claims 只有 uid，
// 所以身份信息只能从库里读。App 在此之前从未调用过 /api/me，属纯增量，
// 零向后兼容风险。
func meHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		uid := CurrentUserID(c)
		if uid == 0 {
			Fail(c, ErrUnauthorized("未认证"))
			return
		}
		u, err := db.GetUserByID(d, uid)
		if err != nil {
			// 令牌有效但用户已被删掉：返回 401 让客户端回登录页，不要 500。
			Fail(c, ErrUnauthorized("用户不存在"))
			return
		}
		OK(c, gin.H{"id": u.ID, "username": u.Username})
	}
}

type changeUsernameRequest struct {
	NewUsername     string `json:"new_username" binding:"required"`
	CurrentPassword string `json:"current_password" binding:"required"`
}

// usernamePattern 限制用户名可用字符。
//
// 只允许 ASCII 字母数字与 _ . -，首字符不能是符号：用户名会出现在登录页、
// 设置页、审计日志里，纯文本展示，禁掉空白/全角/@: 可以免去编码与「admin 」
// 与「admin」看起来一样这类伪装问题。
var usernamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{2,31}$`)

// changeUsernameHandler 修改用户名（M11 新增，Web 端没有这个能力）。
//
// 不重签 token、不动 token_ver：JWT claims 只有 uid/typ/ver，都不含用户名，
// 所以改名与鉴权无关；bump ver 等于把其他设备无故踢下线。
// 客户端显示名通过 /api/me 刷新，不依赖登录响应里的快照。
func changeUsernameHandler(d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		uid := CurrentUserID(c)
		if uid == 0 {
			Fail(c, ErrUnauthorized("未认证"))
			return
		}
		var req changeUsernameRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest("新用户名与当前密码不能为空"))
			return
		}
		if !usernamePattern.MatchString(req.NewUsername) {
			Fail(c, ErrBadRequest("用户名需 3–32 位，以字母或数字开头，只允许字母、数字、下划线、点、短横线"))
			return
		}

		u, err := db.GetUserByID(d, uid)
		if err != nil {
			Fail(c, ErrUnauthorized("用户不存在"))
			return
		}
		if u.Username == req.NewUsername {
			// 不静默返回 200：用户以为改了，实际没变，下次登录才发现。
			Fail(c, ErrBadRequest("新用户名与当前用户名相同"))
			return
		}
		if !auth.VerifyPassword(u.PasswordHash, req.CurrentPassword) {
			Fail(c, ErrUnauthorized("当前密码错误"))
			return
		}

		// 预查只为给出友商文案（大小写不同也算占用）；并发窗口由 UNIQUE 约束兜底。
		taken, err := db.UsernameExistsCI(d, req.NewUsername, uid)
		if err != nil {
			Fail(c, err)
			return
		}
		if taken {
			Fail(c, ErrConflict("该用户名已被占用"))
			return
		}

		if err := db.UpdateUsername(d, uid, req.NewUsername); err != nil {
			if errors.Is(err, db.ErrUsernameTaken) {
				Fail(c, ErrConflict("该用户名已被占用"))
				return
			}
			Fail(c, err)
			return
		}
		OK(c, gin.H{"id": uid, "username": req.NewUsername})
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
			AccessToken:      access,
			RefreshToken:     refresh,
			ExpiresIn:        int(auth.AccessTTL.Seconds()),
			RefreshExpiresAt: time.Now().Add(auth.RefreshTTL).Unix(),
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
