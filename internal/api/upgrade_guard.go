package api

import (
	"sync"
	"time"
)

// 密码二次确认的退避参数。
const (
	// 连续错 5 次即进入退避：足够挡住脚本化试口令，又不至于让手滑的人被锁太久。
	passwordFailLimit = 5
	passwordFailTTL   = 60 * time.Second
)

// passwordGuard 是危险操作（面板自更新）的密码错误退避计数。
//
// 刻意只放内存：重启清零是可接受的代价，换来「不查库、不写表、无额外依赖」。
// map 只按用户 ID 增长（单人部署通常 1 条），不做惰性清理。
type passwordGuard struct {
	mu    sync.Mutex
	fails map[int64]*passwordFail
	now   func() time.Time // 便于测试替换时钟
}

type passwordFail struct {
	count     int
	blockedTo time.Time
}

func newPasswordGuard() *passwordGuard {
	return &passwordGuard{fails: map[int64]*passwordFail{}, now: time.Now}
}

// blockedFor 返回剩余退避秒数；0 表示未在退避（仍需正常校验密码）。
func (g *passwordGuard) blockedFor(uid int64) int {
	g.mu.Lock()
	defer g.mu.Unlock()

	f := g.fails[uid]
	if f == nil || f.blockedTo.IsZero() {
		return 0
	}
	if left := f.blockedTo.Sub(g.now()); left > 0 {
		// 向上取整，避免返回「剩余 0 秒」却仍被拒的歧义文案
		return int(left/time.Second) + 1
	}
	// 退避窗口已过：清零重新计数，不做永久半封
	f.count = 0
	f.blockedTo = time.Time{}
	return 0
}

// fail 记录一次密码错误；达到阈值即进入退避窗口并重新计数。
func (g *passwordGuard) fail(uid int64) {
	g.mu.Lock()
	defer g.mu.Unlock()

	f := g.fails[uid]
	if f == nil {
		f = &passwordFail{}
		g.fails[uid] = f
	}
	f.count++
	if f.count >= passwordFailLimit {
		f.blockedTo = g.now().Add(passwordFailTTL)
		f.count = 0
	}
}

// reset 密码校验成功后清零，下一次触发重新从 0 数。
func (g *passwordGuard) reset(uid int64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.fails, uid)
}
