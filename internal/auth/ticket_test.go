package auth

import (
	"errors"
	"testing"
	"time"
)

func TestWSTicketRoundTrip(t *testing.T) {
	secret := "test-secret"
	token, err := GenerateWSTicket(secret, 7, 42, "abc123")
	if err != nil {
		t.Fatal(err)
	}

	claims, err := ParseWSTicket(secret, token)
	if err != nil {
		t.Fatal(err)
	}
	if claims.UserID != 7 || claims.ServerID != 42 || claims.ContainerID != "abc123" {
		t.Errorf("claims 不匹配: %+v", claims)
	}
	if claims.Type != TypeWSTicket {
		t.Errorf("type=%q", claims.Type)
	}
}

func TestWSTicketWrongSecret(t *testing.T) {
	token, err := GenerateWSTicket("secret-a", 1, 1, "c")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseWSTicket("secret-b", token); !errors.Is(err, ErrInvalidToken) {
		t.Errorf("错误密钥应判无效，实际 %v", err)
	}
}

func TestWSTicketRejectsAccessToken(t *testing.T) {
	secret := "s"
	access, err := GenerateAccessToken(secret, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseWSTicket(secret, access); !errors.Is(err, ErrWrongTokenType) {
		t.Errorf("access token 不能当票据用，实际 %v", err)
	}
}

func TestWSTicketTTLIsShort(t *testing.T) {
	if WSTicketTTL > 5*time.Minute {
		t.Errorf("票据有效期过长: %v（应只够建连）", WSTicketTTL)
	}
	if WSTicketTTL <= 0 {
		t.Errorf("票据有效期非法: %v", WSTicketTTL)
	}
}
