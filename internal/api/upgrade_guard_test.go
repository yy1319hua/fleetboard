package api

import (
	"testing"
	"time"
)

// 连续 5 次密码错 → 进入 60s 退避；窗口过后重新计数。
func TestPasswordGuardBlockAndRecover(t *testing.T) {
	g := newPasswordGuard()
	now := time.Now()
	g.now = func() time.Time { return now }

	const uid = int64(7)
	if got := g.blockedFor(uid); got != 0 {
		t.Fatalf("初始不应退避, got %d", got)
	}

	for i := 1; i < passwordFailLimit; i++ {
		g.fail(uid)
		if got := g.blockedFor(uid); got != 0 {
			t.Fatalf("第 %d 次错误后不应退避, got %d", i, got)
		}
	}

	g.fail(uid) // 第 5 次
	if got := g.blockedFor(uid); got <= 0 {
		t.Fatalf("%d 次错误后应退避, got %d", passwordFailLimit, got)
	}
	if got := g.blockedFor(uid); got > int(passwordFailTTL/time.Second)+1 {
		t.Errorf("退避时长 %ds 超出上限", got)
	}

	// 窗口内前进 59s 仍在退避
	now = now.Add(59 * time.Second)
	if got := g.blockedFor(uid); got <= 0 {
		t.Error("59s 时仍应在退避窗口内")
	}

	// 窗口过后恢复，且计数已清零
	now = now.Add(2 * time.Second)
	if got := g.blockedFor(uid); got != 0 {
		t.Errorf("窗口过后应放行, got %d", got)
	}
}

// 密码校验成功即清零，不会因历史错误次数被拖累。
func TestPasswordGuardReset(t *testing.T) {
	g := newPasswordGuard()
	for i := 0; i < passwordFailLimit-1; i++ {
		g.fail(1)
	}
	g.reset(1)

	// 清零后再错 4 次也不该退避（说明计数确实清了）
	for i := 0; i < passwordFailLimit-1; i++ {
		g.fail(1)
	}
	if got := g.blockedFor(1); got != 0 {
		t.Errorf("reset 后计数应清零, got %d", got)
	}
}

// 退避按用户隔离：一人被锁不影响另一人。
func TestPasswordGuardPerUser(t *testing.T) {
	g := newPasswordGuard()
	for i := 0; i < passwordFailLimit; i++ {
		g.fail(1)
	}
	if got := g.blockedFor(2); got != 0 {
		t.Errorf("其他用户不应受影响, got %d", got)
	}
}
