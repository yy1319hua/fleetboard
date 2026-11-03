package api

import (
	"testing"
	"time"
)

func TestLoginGuardLocksAfterLimit(t *testing.T) {
	g := newLoginGuard()
	base := time.Now()
	g.now = func() time.Time { return base }
	key := "admin|1.2.3.4"

	for i := 1; i < loginFailLimit; i++ {
		g.fail(key)
		if wait := g.blockedFor(key); wait != 0 {
			t.Fatalf("第 %d 次失败不应锁定，wait=%d", i, wait)
		}
	}
	g.fail(key) // 第 loginFailLimit 次
	wait := g.blockedFor(key)
	if wait <= 0 || wait > int(loginLockBase/time.Second)+1 {
		t.Fatalf("第 %d 次失败应锁定约 %v，实际 %ds", loginFailLimit, loginLockBase, wait)
	}

	base = base.Add(loginLockBase + time.Second)
	if wait := g.blockedFor(key); wait != 0 {
		t.Errorf("锁定到期后应放行，实际还差 %ds", wait)
	}
}

func TestLoginGuardEscalates(t *testing.T) {
	g := newLoginGuard()
	base := time.Now()
	g.now = func() time.Time { return base }
	key := "admin|1.2.3.4"

	for i := 0; i < loginFailLimit; i++ {
		g.fail(key)
	}
	base = base.Add(loginLockBase + time.Second)
	if wait := g.blockedFor(key); wait != 0 {
		t.Fatalf("首轮锁定应已到期，wait=%d", wait)
	}

	g.fail(key) // 第 6 次：期间没有成功登录，应翻倍
	wait := g.blockedFor(key)
	if wait <= int(loginLockBase/time.Second) {
		t.Errorf("连续失败应指数升级（期望 >%ds），实际 %ds", int(loginLockBase/time.Second), wait)
	}
	if wait > int(loginLockMax/time.Second)+1 {
		t.Errorf("退避不应超过上限 %v，实际 %ds", loginLockMax, wait)
	}
}

func TestLoginGuardResetOnSuccess(t *testing.T) {
	g := newLoginGuard()
	base := time.Now()
	g.now = func() time.Time { return base }
	key := "admin|1.2.3.4"

	for i := 0; i < loginFailLimit; i++ {
		g.fail(key)
	}
	g.reset(key)

	if wait := g.blockedFor(key); wait != 0 {
		t.Fatalf("登录成功后应清零，wait=%d", wait)
	}
	// 清零后重新从 1 开始数，下一次单次失败不应立即锁定。
	g.fail(key)
	if wait := g.blockedFor(key); wait != 0 {
		t.Errorf("清零后单次失败不应锁定，wait=%d", wait)
	}
}

func TestLoginGuardKeysAreIsolated(t *testing.T) {
	g := newLoginGuard()
	base := time.Now()
	g.now = func() time.Time { return base }

	for i := 0; i < loginFailLimit; i++ {
		g.fail("admin|1.1.1.1")
	}
	if wait := g.blockedFor("admin|1.1.1.1"); wait == 0 {
		t.Fatal("触发阈值的键应被锁定")
	}
	if wait := g.blockedFor("admin|2.2.2.2"); wait != 0 {
		t.Errorf("不同 IP 不应互相连累，wait=%d", wait)
	}
}
