package auth

import (
	"errors"
	"strconv"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// TypeWSTicket 是一次性 WebSocket 票据的类型标识。
const TypeWSTicket = "ws-ticket"

// WSTicketTTL 票据有效期：只够前端建连，过期即废。
const WSTicketTTL = 60 * time.Second

// WSTicketClaims 把票据绑定到「谁 + 哪台服务器 + 哪个容器」，
// 因此即便 URL 泄露，也只能连那一个容器的日志，且 60 秒内有效。
type WSTicketClaims struct {
	UserID      int64  `json:"uid"`
	Type        string `json:"typ"`
	ServerID    int64  `json:"sid"`
	ContainerID string `json:"cid"`
	jwt.RegisteredClaims
}

// GenerateWSTicket 签发 WebSocket 一次性票据。
// 说明：浏览器 WebSocket 无法自带 Authorization 头，故用短期票据走查询参数；
// access token 绝不进 URL（会落到反向代理/Cloudflare 访问日志）。
func GenerateWSTicket(secret string, userID, serverID int64, containerID string) (string, error) {
	now := time.Now()
	claims := WSTicketClaims{
		UserID:      userID,
		Type:        TypeWSTicket,
		ServerID:    serverID,
		ContainerID: containerID,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   strconv.FormatInt(userID, 10),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(WSTicketTTL)),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
}

// ParseWSTicket 校验票据签名、有效期与类型。
func ParseWSTicket(secret, tokenString string) (*WSTicketClaims, error) {
	claims := &WSTicketClaims{}
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
	if claims.Type != TypeWSTicket {
		return nil, ErrWrongTokenType
	}
	return claims, nil
}
