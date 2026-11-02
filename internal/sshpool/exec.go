// Package sshpool 负责 SSH 连接池的建立、复用与回收。
package sshpool

import (
	"strings"

	"golang.org/x/crypto/ssh"
)

// ShPath 是远端执行脚本所用的固定解释器。
//
// 为什么必须显式指定：SSH 的 exec 请求不是交给 /bin/sh，而是交给**远端账号的
// 登录 shell**（/etc/passwd 里的那一栏）。当被管机 root 用 zsh（如 armbian）、
// fish 时，登录 shell 的语义与 POSIX sh 不同——最典型的是 zsh 默认关闭
// SH_WORD_SPLIT，`set -- $a $b` 不会分词，后续 `$((tot2-tot1))` 直接抛
// `bad math expression`。面板的指标采集脚本正是这么写的，于是在 zsh 机器上
// 100% 失败；而「测试连接」只建连、不执行命令，仍然返回 online，表现为
// 「连接不稳定」。
//
// 统一交给 /bin/sh 后，远端行为与登录 shell 无关。
const ShPath = "/bin/sh"

// PrepareScript 把脚本绑定到会话的 stdin，返回应在 Start / Run / Output /
// CombinedOutput 时使用的命令。脚本走 stdin，因此**不需要任何引用或转义**，
// 含单引号、双引号、换行、`$` 都按原样交给 sh。
//
// 用法（注意 StdoutPipe 必须在 Start 之前调用）：
//
//	sess, err := cli.NewSession()
//	cmd := sshpool.PrepareScript(sess, script)
//	out, err := sess.Output(cmd)
//
// 或流式：
//
//	sess, err := cli.NewSession()
//	cmd := sshpool.PrepareScript(sess, script)
//	stdout, _ := sess.StdoutPipe()
//	_ = sess.Start(cmd)
//
// 要求：脚本本身不得再读取 stdin（会把脚本剩余部分当成输入吞掉）。
func PrepareScript(sess *ssh.Session, script string) string {
	sess.Stdin = strings.NewReader(script)
	return ShPath
}

// ShellQuote 把字符串包成单引号字面量，供必须拼成一行命令的场景使用。
// 内部单引号用 POSIX 惯用的「闭引号 + 转义引号 + 开引号」写法拼接，
// bash / sh / zsh 均正确（见 exec_test.go 的用例）。
//
// 能用 PrepareScript 时优先用它：走 stdin 不涉及转义，少一类出错可能。
func ShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
