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

func TestActionCommandAllowed(t *testing.T) {
	roots := []string{"/opt/stacks"}
	cases := map[string]string{
		"up":      "docker compose -f '/opt/stacks/app/docker-compose.yml' --project-directory '/opt/stacks/app' up -d",
		"down":    "docker compose -f '/opt/stacks/app/docker-compose.yml' --project-directory '/opt/stacks/app' down",
		"restart": "docker compose -f '/opt/stacks/app/docker-compose.yml' --project-directory '/opt/stacks/app' restart",
		"ps":      "docker compose -f '/opt/stacks/app/docker-compose.yml' --project-directory '/opt/stacks/app' ps",
	}
	for action, want := range cases {
		got, err := ActionCommand("/opt/stacks/app/docker-compose.yml", action, roots)
		if err != nil {
			t.Fatalf("%s: %v", action, err)
		}
		if got != want {
			t.Errorf("%s:\n got=%q\nwant=%q", action, got, want)
		}
	}
}

func TestActionCommandRejected(t *testing.T) {
	roots := []string{"/opt/stacks"}

	// 动作白名单
	for _, a := range []string{"", "exec", "rm", "up -d; rm -rf /", "DOWN"} {
		if _, err := ActionCommand("/opt/stacks/app/docker-compose.yml", a, roots); err == nil {
			t.Errorf("动作 %q 应被拒绝", a)
		}
	}

	// 路径白名单
	if _, err := ActionCommand("/etc/passwd", "up", roots); !errors.Is(err, ErrPathDenied) {
		t.Errorf("白名单外路径应返回 ErrPathDenied，实际 %v", err)
	}
}

func TestShellQuote(t *testing.T) {
	if got := shellQuote("/root/app.yml"); got != "'/root/app.yml'" {
		t.Errorf("got=%q", got)
	}
	// 含单引号时必须是 '...'\''...' 形式，闭合后再转义
	if got := shellQuote("/root/a'b.yml"); got != `'/root/a'\''b.yml'` {
		t.Errorf("got=%q", got)
	}
}
