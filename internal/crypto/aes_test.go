package crypto

import (
	"strings"
	"testing"
)

func TestEncryptDecryptRoundTrip(t *testing.T) {
	const master = "master-key"
	const plain = "FAKE_PRIVATE_KEY_CONTENT_FOR_TEST_abc123"

	enc, err := Encrypt(master, plain)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if enc == plain {
		t.Fatal("密文不应等于明文")
	}
	if strings.Contains(enc, "FAKE_PRIVATE_KEY_CONTENT") {
		t.Fatal("密文中不应出现明文片段")
	}

	dec, err := Decrypt(master, enc)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if dec != plain {
		t.Errorf("解密结果不一致:\n got=%q\nwant=%q", dec, plain)
	}
}

func TestEncryptIsRandomized(t *testing.T) {
	const master = "m"
	a, err := Encrypt(master, "same")
	if err != nil {
		t.Fatal(err)
	}
	b, err := Encrypt(master, "same")
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Error("随机 nonce 应使两次密文不同")
	}
}

func TestDecryptWrongKey(t *testing.T) {
	enc, err := Encrypt("key-a", "secret")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decrypt("key-b", enc); err == nil {
		t.Error("错误密钥应解密失败")
	}
}

func TestDecryptTampered(t *testing.T) {
	enc, err := Encrypt("k", "secret")
	if err != nil {
		t.Fatal(err)
	}
	// 翻转最后一个字符（base64 内容），GCM 应校验失败
	bad := enc[:len(enc)-2] + "AA"
	if _, err := Decrypt("k", bad); err == nil {
		t.Error("篡改密文应校验失败")
	}
}
