// Package crypto 负责凭据加解密（AES-256-GCM）。
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"io"
)

// DeriveKey 由主密钥（环境变量 KEY）派生 32 字节 AES-256 密钥。
func DeriveKey(master string) []byte {
	sum := sha256.Sum256([]byte(master))
	return sum[:]
}

// Encrypt 使用 AES-256-GCM 加密明文，输出 base64(nonce||ciphertext)。
// 用于存储被管机 SSH 私钥/口令等敏感字段，绝不落明文。
func Encrypt(master, plaintext string) (string, error) {
	block, err := aes.NewCipher(DeriveKey(master))
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	ct := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return base64.StdEncoding.EncodeToString(ct), nil
}

// Decrypt 解密 Encrypt 的产物；密钥不匹配或密文被篡改会返回错误。
func Decrypt(master, ciphertext string) (string, error) {
	data, err := base64.StdEncoding.DecodeString(ciphertext)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(DeriveKey(master))
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	ns := gcm.NonceSize()
	if len(data) < ns {
		return "", errors.New("密文过短")
	}
	nonce, ct := data[:ns], data[ns:]
	pt, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return "", err
	}
	return string(pt), nil
}
