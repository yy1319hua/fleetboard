package auth

import (
	"errors"
	"testing"
)

func TestAccessTokenRoundTrip(t *testing.T) {
	const secret = "test-secret"
	tok, err := GenerateAccessToken(secret, 42, 0)
	if err != nil {
		t.Fatalf("GenerateAccessToken: %v", err)
	}
	c, err := ParseAccessToken(secret, tok)
	if err != nil {
		t.Fatalf("ParseAccessToken: %v", err)
	}
	if c.UserID != 42 {
		t.Errorf("uid=%d, want 42", c.UserID)
	}
	if c.Type != TypeAccess {
		t.Errorf("typ=%q, want access", c.Type)
	}
}

func TestRefreshTokenRoundTrip(t *testing.T) {
	const secret = "test-secret"
	tok, err := GenerateRefreshToken(secret, 7, 0)
	if err != nil {
		t.Fatal(err)
	}
	c, err := ParseRefreshToken(secret, tok)
	if err != nil {
		t.Fatal(err)
	}
	if c.Type != TypeRefresh || c.UserID != 7 {
		t.Errorf("claims=%+v", c)
	}
}

func TestWrongTokenType(t *testing.T) {
	const secret = "s"

	refresh, _ := GenerateRefreshToken(secret, 1, 0)
	if _, err := ParseAccessToken(secret, refresh); !errors.Is(err, ErrWrongTokenType) {
		t.Errorf("refresh 当 access 用：err=%v, want ErrWrongTokenType", err)
	}

	access, _ := GenerateAccessToken(secret, 1, 0)
	if _, err := ParseRefreshToken(secret, access); !errors.Is(err, ErrWrongTokenType) {
		t.Errorf("access 当 refresh 用：err=%v, want ErrWrongTokenType", err)
	}
}

func TestInvalidSecret(t *testing.T) {
	tok, _ := GenerateAccessToken("secret-a", 1, 0)
	if _, err := ParseAccessToken("secret-b", tok); !errors.Is(err, ErrInvalidToken) {
		t.Errorf("err=%v, want ErrInvalidToken", err)
	}
}

func TestTamperedToken(t *testing.T) {
	const secret = "s"
	tok, _ := GenerateAccessToken(secret, 1, 0)
	if _, err := ParseAccessToken(secret, tok+"x"); !errors.Is(err, ErrInvalidToken) {
		t.Errorf("err=%v, want ErrInvalidToken", err)
	}
}
