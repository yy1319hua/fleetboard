package sshpool

import (
	"io"
	"os/exec"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

// 脚本必须原样进出：走 stdin 的意义就是不经历任何 shell 解析。
func TestPrepareScriptKeepsBody(t *testing.T) {
	sess := &ssh.Session{}
	script := "set -- $a $b; echo \"it's $HOME\"\nprintf '%s\\n' ok"

	cmd := PrepareScript(sess, script)

	if cmd != ShPath {
		t.Fatalf("cmd=%q, want %q", cmd, ShPath)
	}
	if sess.Stdin == nil {
		t.Fatal("Stdin 未设置，脚本会丢失")
	}
	got, err := io.ReadAll(sess.Stdin)
	if err != nil {
		t.Fatalf("读取 Stdin: %v", err)
	}
	if string(got) != script {
		t.Fatalf("脚本被改写：got %q", script)
	}
}

func TestShellQuote(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "''"},
		{"abc", "'abc'"},
		{"it's", `'it'\''s'`},
		{"a'b'c", `'a'\''b'\''c'`},
		{"$HOME", "'$HOME'"},
	}
	for _, c := range cases {
		if got := ShellQuote(c.in); got != c.want {
			t.Errorf("ShellQuote(%q)=%q, want %q", c.in, got, c.want)
		}
	}
}

// 回归：指标脚本依赖 `set -- $a $b` 的隐式分词，这在 sh 下成立、在 zsh 下不成立。
// 本测试把同一段脚本经 stdin 喂给 /bin/sh，断言四个字段能正确拆开。
func TestMetricsSplitWorksUnderSh(t *testing.T) {
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("本机无 sh")
	}
	script := `a="11 22"; b="33 44"; set -- $a $b; ` +
		`dt=$((4-2)); printf "%s|%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" "$dt"`

	cmd := exec.Command(ShPath)
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("sh 执行失败: %v", err)
	}
	if got := strings.TrimSpace(string(out)); got != "11|22|33|44|2" {
		t.Fatalf("分词结果 %q，期望 11|22|33|44|2", got)
	}
}
