package api

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"v0.4.1", "v0.4.0", 1},
		{"v0.4.0", "v0.4.0", 0},
		{"0.4.0", "v0.4.0", 0},   // v 前缀不参与比较
		{"V0.4.0", "0.4.0", 0},   // 大写前缀同义
		{"v0.10.0", "v0.9.9", 1}, // 按数字段比，不是字典序
		{"v0.9.9", "v0.10.0", -1},
		{"v0.4", "v0.4.0", 0}, // 缺段补 0
		{"", "v0.1.0", -1},    // 空串按 0 处理
		{"v0.0.0", "", 0},
		{"v0.5.0-beta.1", "v0.5.0", 0}, // 预发布后缀忽略
		{"v1.2.3+build7", "v1.2.3", 0}, // 构建元数据忽略
		{"v2.0.0", "v1.99.99", 1},
	}
	for _, c := range cases {
		if got := compareVersions(c.a, c.b); got != c.want {
			t.Errorf("compareVersions(%q,%q)=%d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestHasVersionNumber(t *testing.T) {
	// dev/unknown 这类构建标记不可比较，必须被判为「无版本号」，
	// 否则 dev 构建会把 GitHub 上的任何 tag 都当成「有新版」。
	for _, v := range []string{"dev", "", "unknown", "local"} {
		if hasVersionNumber(v) {
			t.Errorf("%q 不应被判为含版本号", v)
		}
	}
	for _, v := range []string{"v0.4.0", "0.0.1", "1"} {
		if !hasVersionNumber(v) {
			t.Errorf("%q 应含版本号", v)
		}
	}
}

// 10 分钟缓存：窗口内重复查询不得再次外呼。
func TestGitHubVersionSourceCacheHit(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		if ua := r.Header.Get("User-Agent"); ua == "" {
			t.Errorf("GitHub 强制要求 User-Agent")
		}
		_, _ = w.Write([]byte(`{"tag_name":"v0.4.1"}`))
	}))
	defer srv.Close()

	src := newGitHubVersionSource()
	src.url = srv.URL
	src.client = srv.Client()

	for i := 0; i < 3; i++ {
		v, err := src.Latest(context.Background())
		if err != nil {
			t.Fatalf("第 %d 次查询失败: %v", i, err)
		}
		if v != "v0.4.1" {
			t.Fatalf("版本=%q, want v0.4.1", v)
		}
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Errorf("外呼 %d 次, want 1（缓存命中不应重复请求）", n)
	}
}

// 缓存过期后必须重新外呼。
func TestGitHubVersionSourceCacheExpiry(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		if n == 1 {
			_, _ = w.Write([]byte(`{"tag_name":"v0.4.1"}`))
			return
		}
		_, _ = w.Write([]byte(`{"tag_name":"v0.4.2"}`))
	}))
	defer srv.Close()

	src := newGitHubVersionSource()
	src.url = srv.URL
	src.client = srv.Client()
	src.ttl = time.Millisecond // 立刻过期，无需 sleep 长时

	if v, _ := src.Latest(context.Background()); v != "v0.4.1" {
		t.Fatalf("首次=%q", v)
	}
	time.Sleep(5 * time.Millisecond)
	if v, _ := src.Latest(context.Background()); v != "v0.4.2" {
		t.Errorf("过期后应拿到新版本, 实际 %q", v)
	}
}

// 失败也要短暂缓存：GitHub 抖动时不能让每个请求都白等满 5s。
func TestGitHubVersionSourceErrorCache(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.WriteHeader(http.StatusForbidden) // 速率限制的典型响应
	}))
	defer srv.Close()

	src := newGitHubVersionSource()
	src.url = srv.URL
	src.client = srv.Client()

	for i := 0; i < 3; i++ {
		if _, err := src.Latest(context.Background()); err == nil {
			t.Fatal("403 应返回错误，交给上层降级")
		}
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Errorf("外呼 %d 次, want 1（失败缓存生效）", n)
	}
}

// 缺 tag_name 属于上游异常，同样降级为错误。
func TestGitHubVersionSourceEmptyTag(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"tag_name":"  "}`))
	}))
	defer srv.Close()

	src := newGitHubVersionSource()
	src.url = srv.URL
	src.client = srv.Client()

	if _, err := src.Latest(context.Background()); err == nil {
		t.Fatal("空 tag_name 应报错")
	}
}

// 超时由 5s 上限兜住：这里验证 ctx 取消能立刻返回，不挂死请求。
func TestGitHubVersionSourceContextCancel(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()

	src := newGitHubVersionSource()
	src.url = srv.URL
	src.client = srv.Client()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := src.Latest(ctx); err == nil || errors.Is(err, context.Canceled) == false {
		t.Errorf("应因 ctx 取消而失败: %v", err)
	}
}
