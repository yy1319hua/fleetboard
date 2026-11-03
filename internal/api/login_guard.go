package api

import (
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// 登录失败退避参数。
const (
	// 连续错 5 次开始退避：手滑打错几次不至于被锁，脚本化试口令立刻撞墙。
	loginFailLimit = 5
	loginLockBase  = 30 * time.Second
	loginLockMax   = 15 * time.Minute
	// 记录保留时长：长期不再出现的键不必常驻内存。
	loginEntryTTL = 24 * time.Hour
)

// loginGuard 按「用户名 + 客户端 IP」对登录失败做指数退避。
//
// 与 passwordGuard 的区别：登录发生在认证之前，没有 uid 可用，键只能取自请求；
// 而且它必须存在——面板一旦暴露到公网，无限制的登录接口等于把口令哈希交给
// 离线爆破。只放内存：重启清零是可接受的代价，换来不查库、不写表。
type loginGuard struct {
	mu    sync.Mutex
	fails map[string]*loginFail
	now   func() time.Time // 便于测试替换时钟
}

type loginFail struct {
	count     int
	blockedTo time.Time
	seen      time.Time
}

func newLoginGuard() *loginGuard {
	return &loginGuard{fails: map[string]*loginFail{}, now: time.Now}
}

// blockedFor 返回剩余锁定秒数；0 表示可以尝试。
func (g *loginGuard) blockedFor(key string) int {
	g.mu.Lock()
	defer g.mu.Unlock()

	f := g.fails[key]
	if f == nil {
		return 0
	}
	now := g.now()
	if now.Sub(f.seen) > loginEntryTTL {
		delete(g.fails, key)
		return 0
	}
	if f.blockedTo.IsZero() {
		return 0
	}
	if left := f.blockedTo.Sub(now); left > 0 {
		// 向上取整：避免出现「剩余 0 秒」却仍被拒的歧义文案。
		return int(left/time.Second) + 1
	}
	// 锁定到点，放行。刻意保留 count：连续失败（期间没有一次成功登录）
	// 才继续升级退避；成功登录会 reset 整个记录。
	f.blockedTo = time.Time{}
	return 0
}

// fail 记一次失败；达到阈值后按 2 的幂指数退避，封顶 loginLockMax。
func (g *loginGuard) fail(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()

	f := g.fails[key]
	if f == nil {
		f = &loginFail{}
		g.fails[key] = f
	}
	now := g.now()
	f.seen = now
	f.count++
	if f.count < loginFailLimit {
		return
	}
	// 第 5 次错 → 30s，第 6 次 → 60s …… 封顶 15 分钟。
	shift := f.count - loginFailLimit
	if shift > 6 {
		shift = 6
	}
	lock := loginLockBase << shift
	if lock <= 0 || lock > loginLockMax {
		lock = loginLockMax
	}
	f.blockedTo = now.Add(lock)
}

// reset 登录成功后清零，下次从 0 开始计数。
func (g *loginGuard) reset(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.fails, key)
}

// loginKey 组合限流键。
//
// 用户名统一转小写：SQLite 的用户名比对不区分大小写，若按原样分键，
// 攻击者换大小写即可绕过退避。带上 IP 是为了不让别人的失败连累自己。
func loginKey(c *gin.Context, username string) string {
	return strings.ToLower(strings.TrimSpace(username)) + "|" + c.ClientIP()
}
