package auth

import "golang.org/x/crypto/bcrypt"

// HashPassword 用 bcrypt 生成密码哈希（自带随机盐）。
func HashPassword(pass string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(pass), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// VerifyPassword 校验明文密码与 bcrypt 哈希是否匹配。
func VerifyPassword(hash, pass string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(pass)) == nil
}
