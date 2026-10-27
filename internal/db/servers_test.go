package db

import (
	"errors"
	"testing"
)

const testMasterKey = "test-master-key"

func TestCreateServerStoresEncrypted(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	s, err := CreateServer(d, testMasterKey, CreateServerInput{
		Name:       "vps1",
		Host:       "1.2.3.4",
		AuthMethod: "key",
		PrivateKey: "PRIVATE-KEY-CONTENT",
	})
	if err != nil {
		t.Fatalf("CreateServer: %v", err)
	}
	if s.ID == 0 || s.Name != "vps1" {
		t.Errorf("server=%+v", s)
	}

	// 直接查库：落库必须是密文
	var keyEnc string
	if err := d.QueryRow(`SELECT key_enc FROM ssh_credentials WHERE server_id = ?`, s.ID).Scan(&keyEnc); err != nil {
		t.Fatal(err)
	}
	if keyEnc == "" || keyEnc == "PRIVATE-KEY-CONTENT" {
		t.Fatalf("私钥未加密存储: %q", keyEnc)
	}

	c, err := GetDecryptedCredential(d, testMasterKey, s.ID)
	if err != nil {
		t.Fatalf("GetDecryptedCredential: %v", err)
	}
	if c.PrivateKey != "PRIVATE-KEY-CONTENT" {
		t.Errorf("解密私钥=%q", c.PrivateKey)
	}
	if c.AuthMethod != "key" {
		t.Errorf("auth_method=%q", c.AuthMethod)
	}
}

func TestCreateServerDefaults(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	s, err := CreateServer(d, testMasterKey, CreateServerInput{Name: "h", Host: "h"})
	if err != nil {
		t.Fatal(err)
	}
	if s.Port != 22 {
		t.Errorf("port=%d, want 22", s.Port)
	}
	if s.SSHUser != "root" {
		t.Errorf("ssh_user=%q, want root", s.SSHUser)
	}
	if s.AuthMethod != "key" {
		t.Errorf("auth_method=%q, want key", s.AuthMethod)
	}
}

func TestCreateServerRequiresNameHost(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	if _, err := CreateServer(d, testMasterKey, CreateServerInput{}); err == nil {
		t.Error("缺名称/主机应报错")
	}
}

func TestListAndGetServer(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	s1, err := CreateServer(d, testMasterKey, CreateServerInput{Name: "a", Host: "a"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := CreateServer(d, testMasterKey, CreateServerInput{Name: "b", Host: "b"}); err != nil {
		t.Fatal(err)
	}

	list, err := ListServers(d)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 {
		t.Errorf("len=%d, want 2", len(list))
	}

	got, err := GetServer(d, s1.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "a" {
		t.Errorf("name=%q", got.Name)
	}
}

func TestGetServerNotFound(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	if _, err := GetServer(d, 999); !errors.Is(err, ErrServerNotFound) {
		t.Errorf("err=%v, want ErrServerNotFound", err)
	}
}

func TestDeleteServerCascades(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	s, err := CreateServer(d, testMasterKey, CreateServerInput{Name: "x", Host: "x", PrivateKey: "k"})
	if err != nil {
		t.Fatal(err)
	}
	if err := DeleteServer(d, s.ID); err != nil {
		t.Fatalf("DeleteServer: %v", err)
	}
	if _, err := GetServer(d, s.ID); !errors.Is(err, ErrServerNotFound) {
		t.Errorf("删除后应查不到: %v", err)
	}

	var n int
	if err := d.QueryRow(`SELECT COUNT(1) FROM ssh_credentials WHERE server_id = ?`, s.ID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("凭据未级联删除: n=%d", n)
	}
}

func TestDeleteServerNotFound(t *testing.T) {
	d := openTestDB(t)
	defer d.Close()

	if err := DeleteServer(d, 12345); !errors.Is(err, ErrServerNotFound) {
		t.Errorf("err=%v, want ErrServerNotFound", err)
	}
}
