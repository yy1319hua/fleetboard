package auth

import (
	"errors"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Claims 是最小身份载荷：用户 ID + 令牌类型。
type Claims struct {
	UserID int64  `json:"uid"`
	Type   string `json:"typ"` // "access" | "refresh"
	Ver    int64  `json:"ver"` // token epoch：与 users.token_ver 比对，不匹配即吊销（M8.1e）
	jwt.RegisteredClaims
}

// 令牌类型与有效期。
const (
	TypeAccess  = "access"
	TypeRefresh = "refresh"

	AccessTTL  = 15 * time.Minute
	RefreshTTL = 7 * 24 * time.Hour
)

// JWT_EPOCH 是全局部署 epoch（M9.0b「ver 协同」）。
// 初始 0：升级不踢现有会话（既有 token 的 Ver 取自各自 users.token_ver，互不影响）。
// 仅在需要强制全局重登时由服务端显式 bump；bootstrap 将其作为 data.ver 下发给 App 做协同判定。
const JWT_EPOCH = 0

var (
	ErrInvalidToken   = errors.New("invalid token")
	ErrExpiredToken   = errors.New("token expired")
	ErrWrongTokenType = errors.New("wrong token type")
)

func sign(secret string, userID, ver int64, typ string, ttl time.Duration) (string, error) {
	now := time.Now()
	claims := Claims{
		UserID: userID,
		Type:   typ,
		Ver:    ver,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   strconv.FormatInt(userID, 10),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
}

// GenerateAccessToken 生成短时效访问令牌（15 分钟）。
func GenerateAccessToken(secret string, userID, ver int64) (string, error) {
	return sign(secret, userID, ver, TypeAccess, AccessTTL)
}

// GenerateRefreshToken 生成刷新令牌（7 天）。
func GenerateRefreshToken(secret string, userID, ver int64) (string, error) {
	return sign(secret, userID, ver, TypeRefresh, RefreshTTL)
}

// ParseToken 校验签名与有效期并返回载荷（不校验类型）。
func ParseToken(secret, tokenString string) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return []byte(secret), nil
	})
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, ErrExpiredToken
		}
		return nil, ErrInvalidToken
	}
	if !token.Valid {
		return nil, ErrInvalidToken
	}
	return claims, nil
}

// ParseAccessToken 校验并要求类型为 access。
func ParseAccessToken(secret, tokenString string) (*Claims, error) {
	c, err := ParseToken(secret, tokenString)
	if err != nil {
		return nil, err
	}
	if c.Type != TypeAccess {
		return nil, ErrWrongTokenType
	}
	return c, nil
}

// ParseRefreshToken 校验并要求类型为 refresh。
func ParseRefreshToken(secret, tokenString string) (*Claims, error) {
	c, err := ParseToken(secret, tokenString)
	if err != nil {
		return nil, err
	}
	if c.Type != TypeRefresh {
		return nil, ErrWrongTokenType
	}
	return c, nil
}
