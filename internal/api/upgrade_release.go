package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// 最新版本的来源与缓存参数。
const (
	latestReleaseURL = "https://api.github.com/repos/yy1319hua/fleetboard/releases/latest"
	// 5s 是外呼硬上限：App 打开升级页时要立刻有反馈，等不起 GitHub 的慢响应。
	releaseTimeout = 5 * time.Second
	// 10 分钟内重复查询不重复外呼（GitHub 匿名 API 有速率限制，且版本号几小时才变一次）。
	releaseCacheTTL = 10 * time.Minute
	// 失败也短暂缓存 60s：GitHub 抖动或被限流时，不能让每个请求都白等满 5s。
	releaseErrTTL = 60 * time.Second
	// 响应体上限：只需要 tag_name，不下载完整 release 描述。
	releaseBodyLimit = 64 << 10
)

// versionSource 提供「最新可用版本」。
// 生产实现走 GitHub Releases；抽成接口是为了让 handler 的失败降级分支可测。
type versionSource interface {
	Latest(ctx context.Context) (string, error)
}

// githubVersionSource 带进程内缓存的 GitHub Releases 查询器。
//
// 缓存是「单条目」而非 LRU：仓库只有一个，查询维度也只有 latest 一条。
type githubVersionSource struct {
	url    string
	client *http.Client
	ttl    time.Duration
	errTTL time.Duration

	mu     sync.Mutex
	val    string
	valExp time.Time
	err    error
	errExp time.Time
}

// newGitHubVersionSource 构造带缓存的生产实现。
func newGitHubVersionSource() *githubVersionSource {
	return &githubVersionSource{
		url:    latestReleaseURL,
		client: &http.Client{Timeout: releaseTimeout},
		ttl:    releaseCacheTTL,
		errTTL: releaseErrTTL,
	}
}

// Latest 返回最新版本 tag（如 v0.4.1）；命中缓存时不发起网络请求。
func (g *githubVersionSource) Latest(ctx context.Context) (string, error) {
	now := time.Now()
	g.mu.Lock()
	if g.val != "" && now.Before(g.valExp) {
		v := g.val
		g.mu.Unlock()
		return v, nil
	}
	if g.err != nil && now.Before(g.errExp) {
		err := g.err
		g.mu.Unlock()
		return "", err
	}
	g.mu.Unlock()

	// 外呼不加锁：慢请求不能把其它请求一起堵住（并发情况下允许少量重复请求）。
	v, err := g.fetch(ctx)

	g.mu.Lock()
	defer g.mu.Unlock()
	if err != nil {
		g.err, g.errExp = err, time.Now().Add(g.errTTL)
		return "", err
	}
	g.val, g.valExp = v, time.Now().Add(g.ttl)
	g.err, g.errExp = nil, time.Time{}
	return v, nil
}

func (g *githubVersionSource) fetch(ctx context.Context) (string, error) {
	// 独立超时：调用方 ctx 可能更长，但外呼本身不允许超过 5s。
	ctx, cancel := context.WithTimeout(ctx, releaseTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	// GitHub 强制要求 User-Agent，缺失直接 403。
	req.Header.Set("User-Agent", "fleetboard")

	resp, err := g.client.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		// 403 多为速率限制：调用方降级为「无法获取最新版本」，不重试、不阻塞请求。
		return "", fmt.Errorf("GitHub Releases 返回 %d", resp.StatusCode)
	}

	var payload struct {
		TagName string `json:"tag_name"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, releaseBodyLimit)).Decode(&payload); err != nil {
		return "", err
	}
	tag := strings.TrimSpace(payload.TagName)
	if tag == "" {
		return "", errors.New("GitHub Releases 未返回 tag_name")
	}
	return tag, nil
}

// compareVersions 语义化版本比较，返回 -1 / 0 / 1。
//
// 规则刻意做得很笨：剥掉 v 前缀与 -pre/+build 后缀，按 . 切段，每段取前导数字（无则 0），
// 缺段补 0。这样 v0.4 == 0.4.0 == V0.4.0.0，空串等价于 0——
// 目标只是「能不能升级」这一个布尔判断，不需要严格的 SemVer 全序。
func compareVersions(a, b string) int {
	as, bs := versionSegments(a), versionSegments(b)
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		x, y := 0, 0
		if i < len(as) {
			x = as[i]
		}
		if i < len(bs) {
			y = bs[i]
		}
		if x == y {
			continue
		}
		if x < y {
			return -1
		}
		return 1
	}
	return 0
}

// versionSegments 把 "v1.2.3-beta.1+build5" 切成 [1,2,3]。
func versionSegments(v string) []int {
	v = strings.TrimSpace(v)
	v = strings.TrimLeft(v, "vV")
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	if v == "" {
		return nil
	}
	parts := strings.Split(v, ".")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n := 0
		for i := 0; i < len(p) && p[i] >= '0' && p[i] <= '9'; i++ {
			n = n*10 + int(p[i]-'0')
		}
		out = append(out, n)
	}
	return out
}

// hasVersionNumber 判断版本串里是否含数字段：
// "dev" / "unknown" 这类本地构建标记不可比较，不能据此判断「有新版本」。
func hasVersionNumber(v string) bool {
	return strings.IndexFunc(v, func(r rune) bool { return r >= '0' && r <= '9' }) >= 0
}
