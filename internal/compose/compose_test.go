package compose

import (
	"errors"
	"testing"
)

func TestIsComposeFile(t *testing.T) {
	yes := []string{
		"docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
		"Docker-Compose.YML", "docker-compose.prod.yml", "compose.dev.yaml",
		"docker-compose.override.yml", "compose-stack.yml",
	}
	for _, n := range yes {
		if !IsComposeFile(n) {
			t.Errorf("%q 应识别为 compose 文件", n)
		}
	}

	no := []string{
		"", "values.yml", "app.yaml", "docker-compose.txt", "docker-compose",
		"my-compose.yml", "composefile.yml", ".env",
	}
	for _, n := range no {
		if IsComposeFile(n) {
			t.Errorf("%q 不应识别为 compose 文件", n)
		}
	}
}

func TestValidatePathAllowed(t *testing.T) {
	roots := []string{"/root", "/opt/stacks", "/etc"}
	ok := []string{
		"/root/docker-compose.yml",
		"/root",                       // 根目录本身允许（用于列目录）
		"/opt/stacks/app/compose.yml", // 嵌套根
		"/etc/compose.yml",
		"/root/a/../b/compose.yml", // clean 后仍在白名单内
	}
	for _, p := range ok {
		if err := ValidatePath(p, roots); err != nil {
			t.Errorf("%q 应允许: %v", p, err)
		}
	}
}

func TestValidatePathDenied(t *testing.T) {
	roots := []string{"/root", "/opt/stacks"}
	denied := []string{
		"",
		"root/compose.yml",             // 非绝对路径
		"/etc/passwd",                  // 不在白名单
		"/opt/compose.yml",             // /opt 本身不在白名单（只允许 /opt/stacks）
		"/root/../etc/passwd",          // 穿越
		"/opt/stacks/../../etc/passwd", // 穿越
		"/rootx/compose.yml",           // 前缀相同但不是子目录
		"/root/compose.yml\x00",        // 含 NUL
	}
	for _, p := range denied {
		err := ValidatePath(p, roots)
		if err == nil {
			t.Errorf("%q 应拒绝", p)
			continue
		}
		if p == "" || p == "root/compose.yml" || p == "/root/compose.yml\x00" {
			continue
		}
		if !errors.Is(err, ErrPathDenied) {
			t.Errorf("%q 应返回 ErrPathDenied，实际 %v", p, err)
		}
	}
}

func TestNormalizeRoots(t *testing.T) {
	if got := NormalizeRoots(nil); len(got) != len(DefaultRoots) {
		t.Errorf("空入参应回落默认白名单，得到 %v", got)
	}
	got := NormalizeRoots([]string{" /opt/stacks/ ", "", "/srv//x"})
	want := []string{"/opt/stacks", "/srv/x"}
	if len(got) != len(want) {
		t.Fatalf("got=%v want=%v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("got[%d]=%q want=%q", i, got[i], want[i])
		}
	}
}
