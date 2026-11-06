package api

import (
	"errors"
	"testing"
)

// 尺寸夹紧：客户端在软键盘弹出/收起时可能算出 0 行或负数，
// 透传给 RequestPty 会让远端 $LINES 变成 0，less/vim 直接画空屏。
func TestClampInt(t *testing.T) {
	cases := []struct{ in, lo, hi, want int }{
		{0, 20, 500, 20},
		{-5, 20, 500, 20},
		{19, 20, 500, 20},
		{80, 20, 500, 80},
		{501, 20, 500, 500},
		{1 << 30, 5, 200, 200},
	}
	for _, c := range cases {
		if got := clampInt(c.in, c.lo, c.hi); got != c.want {
			t.Errorf("clampInt(%d,%d,%d)=%d want %d", c.in, c.lo, c.hi, got, c.want)
		}
	}
}

func TestTermExitCode(t *testing.T) {
	if got := termExitCode(nil); got != 0 {
		t.Errorf("正常退出应为 0，得到 %d", got)
	}
	// 连接被掐断不是 exit 码，用 -1 区分「没跑完」与「跑完但非零」。
	// （*ssh.ExitError 带未导出字段，只能由 true SSH 会话产生，单测里造不出来，
	//  其分支由真机/联调覆盖。）
	if got := termExitCode(errors.New("connection reset")); got != -1 {
		t.Errorf("非 ExitError 应为 -1，得到 %d", got)
	}
}

// 并发上限：满 3 个后第 4 个必须被拒，释放一个后能再进。
func TestTermSlots(t *testing.T) {
	const id int64 = 424242
	for i := 0; i < termMaxPerServer; i++ {
		if !termAcquire(id) {
			t.Fatalf("第 %d 个应允许", i+1)
		}
	}
	if termAcquire(id) {
		t.Fatalf("超过 %d 个仍被允许", termMaxPerServer)
	}
	termRelease(id)
	if !termAcquire(id) {
		t.Fatal("释放后应可再进")
	}
	for i := 0; i < termMaxPerServer; i++ {
		termRelease(id)
	}
	if _, ok := termSlots.m[id]; ok {
		t.Fatal("计数归零后应删除键，避免 map 常驻增长")
	}
}
