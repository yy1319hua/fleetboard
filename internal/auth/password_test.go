package auth

import "testing"

func TestHashAndVerify(t *testing.T) {
	hash, err := HashPassword("s3cret")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if hash == "s3cret" {
		t.Fatal("不应存明文密码")
	}
	if !VerifyPassword(hash, "s3cret") {
		t.Error("正确密码应校验通过")
	}
	if VerifyPassword(hash, "wrong") {
		t.Error("错误密码不应校验通过")
	}
}

func TestHashUnique(t *testing.T) {
	h1, err := HashPassword("same")
	if err != nil {
		t.Fatal(err)
	}
	h2, err := HashPassword("same")
	if err != nil {
		t.Fatal(err)
	}
	if h1 == h2 {
		t.Error("bcrypt 自带随机盐，两次哈希结果应不同")
	}
}
