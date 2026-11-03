package api

import (
	"context"
	"database/sql"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/sshpool"
	"golang.org/x/crypto/ssh"
)

// 这一组测的是 SSE 主循环的三条行为，它们退化时用户看到的现象都很隐蔽：
//   - 断连被当成取消 → 手机切后台，apt 升级被腰斩；
//   - 同 opId 未挡住副作用 → 弱网重试跑第二遍全量升级；
//   - 取消不走 DELETE → 界面说已取消，远端仍在改系统。
//
// 之前只测到「连不上返回 502」，主循环完全没覆盖。现在把建连与执行两个
// 外部动作抽成 pkgUpgradeDeps，用桩驱动整条流。

func newStreamTestServer(
	t *testing.T,
	run func(ctx context.Context, cli *ssh.Client, onLine func(string)) error,
) *gin.Engine {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "stream.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(func(c *gin.Context) {
		c.Set(ctxUserID, int64(1))
		c.Next()
	})

	deps := pkgUpgradeDeps{
		open: func(*gin.Context, *sql.DB, string, *sshpool.Pool, int64) (*ssh.Client, error) {
			return nil, nil // 桩：不真的建连，run 也不碰这个参数
		},
		run: run,
	}
	r.POST("/api/servers/:id/packages/update",
		packageUpdateHandlerWith(d, "test-master-key", sshpool.NewPool(time.Minute), deps))
	r.DELETE("/api/jobs/:id", jobDeleteHandler())
	return r
}

func jobIDFromLocation(t *testing.T, resp *http.Response) string {
	t.Helper()
	loc := resp.Header.Get("Location")
	const prefix = "/api/jobs/"
	if !strings.HasPrefix(loc, prefix) {
		t.Fatalf("Location 头应为 %s<id>，实际 %q", prefix, loc)
	}
	return strings.TrimPrefix(loc, prefix)
}

func startUpdate(t *testing.T, srv *httptest.Server, opID string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+"/api/servers/1/packages/update", nil)
	if err != nil {
		t.Fatalf("构造请求: %v", err)
	}
	if opID != "" {
		req.Header.Set("X-Client-Op-Id", opID)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("发起升级: %v", err)
	}
	return resp
}

func TestPackageUpdateSSEStreamsLinesThenDone(t *testing.T) {
	r := newStreamTestServer(t, func(_ context.Context, _ *ssh.Client, onLine func(string)) error {
		onLine("Reading package lists...")
		onLine("0 upgraded, 0 newly installed")
		return nil
	})
	srv := httptest.NewServer(r)
	defer srv.Close()

	resp := startUpdate(t, srv, "")
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("状态码 %d，期望 202", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "text/event-stream") {
		t.Errorf("Content-Type=%q，期望 SSE", ct)
	}
	jobID := jobIDFromLocation(t, resp)
	if jobID == "" {
		t.Fatal("Location 里没有 jobId")
	}

	body, _ := io.ReadAll(resp.Body)
	got := string(body)
	for _, want := range []string{
		`"event":"started"`,
		`"jobId":"` + jobID + `"`,
		`Reading package lists...`,
		`0 upgraded, 0 newly installed`,
		`"event":"done"`,
		`"ok":true`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("SSE 流缺少 %q\n完整流:\n%s", want, got)
		}
	}

	j := jobStore.Get(jobID)
	if j == nil {
		t.Fatal("job 未登记到 jobStore")
	}
	if snap := j.Snapshot(); snap.Status != JobDone {
		t.Errorf("终态 %q，期望 done", snap.Status)
	}
}

// 断连必须只是 detach：手机切后台/锁屏都会断流，如果把断连当取消，
// 用户回来会看到一个「已取消」的 apt 全量升级（系统可能处于半升级态）。
func TestPackageUpdateDisconnectDetachesInsteadOfCancelling(t *testing.T) {
	release := make(chan struct{})
	started := make(chan struct{})
	var once atomic.Bool

	r := newStreamTestServer(t, func(ctx context.Context, _ *ssh.Client, onLine func(string)) error {
		onLine("upgrading...")
		if once.CompareAndSwap(false, true) {
			close(started)
		}
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	})
	srv := httptest.NewServer(r)
	defer srv.Close()

	resp := startUpdate(t, srv, "detach-op-1")
	jobID := jobIDFromLocation(t, resp)
	defer func() { _ = resp.Body.Close() }()

	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("升级桩没有被调用")
	}

	// 模拟客户端断连。
	_ = resp.Body.Close()

	// 断连之后 job 必须仍在跑，而不是被取消。
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		j := jobStore.Get(jobID)
		if j == nil {
			t.Fatal("job 丢失")
		}
		if st := j.Snapshot().Status; st == JobCancelled || st == JobFailed {
			t.Fatalf("断连把任务终止了，状态 %q", st)
		}
		time.Sleep(50 * time.Millisecond)
	}

	close(release) // 让升级自然结束

	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if j := jobStore.Get(jobID); j != nil && j.Snapshot().Status == JobDone {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("升级结束后 job 未进入 done")
}

// 同 opId 命中活跃任务时只能补发已有输出，不能再跑一次升级。
func TestPackageUpdateSameOpIDDoesNotRunTwice(t *testing.T) {
	release := make(chan struct{})
	var runs atomic.Int32

	r := newStreamTestServer(t, func(ctx context.Context, _ *ssh.Client, onLine func(string)) error {
		runs.Add(1)
		onLine("working...")
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	})
	srv := httptest.NewServer(r)
	defer srv.Close()

	const opID = "same-op-1"

	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		resp := startUpdate(t, srv, opID)
		defer func() { _ = resp.Body.Close() }()
		_, _ = io.ReadAll(resp.Body) // 读到终态，避免连接悬挂
	}()

	// 等第一次真正跑起来（runner 已被调用）。
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && runs.Load() == 0 {
		time.Sleep(20 * time.Millisecond)
	}
	if runs.Load() == 0 {
		t.Fatal("第一次请求没有执行升级")
	}

	// 第二次（弱网重试）用同一 opId，读到终态为止。
	go func() {
		time.Sleep(150 * time.Millisecond)
		close(release)
	}()
	resp2 := startUpdate(t, srv, opID)
	body2, _ := io.ReadAll(resp2.Body)
	_ = resp2.Body.Close()

	if got := runs.Load(); got != 1 {
		t.Errorf("同 opId 触发了 %d 次升级，期望 1 次", got)
	}
	if !strings.Contains(string(body2), `"reused":true`) {
		t.Errorf("第二个连接应收到 reused 标记，实际:\n%s", body2)
	}
	<-firstDone
}

// 取消必须走 DELETE /api/jobs/:id：只有它能取消 job ctx → 远端 apt 收到 SIGINT。
func TestPackageUpdateCancelViaDelete(t *testing.T) {
	r := newStreamTestServer(t, func(ctx context.Context, _ *ssh.Client, _ func(string)) error {
		<-ctx.Done()
		return ctx.Err()
	})
	srv := httptest.NewServer(r)
	defer srv.Close()

	resp := startUpdate(t, srv, "cancel-op-1")
	defer func() { _ = resp.Body.Close() }()
	jobID := jobIDFromLocation(t, resp)

	// 等 job 进入 running 再取消，避免与创建竞争。
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if j := jobStore.Get(jobID); j != nil && j.Snapshot().Status == JobRunning {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	req, err := http.NewRequest(http.MethodDelete, srv.URL+"/api/jobs/"+jobID, nil)
	if err != nil {
		t.Fatalf("构造取消请求: %v", err)
	}
	delResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("取消请求: %v", err)
	}
	_ = delResp.Body.Close()
	if delResp.StatusCode != http.StatusOK {
		t.Fatalf("取消失败，状态码 %d", delResp.StatusCode)
	}

	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), `"canceled":true`) {
		t.Errorf("客户端应收到 canceled 帧，实际:\n%s", body)
	}
	if j := jobStore.Get(jobID); j == nil || j.Snapshot().Status != JobCancelled {
		t.Errorf("job 状态应为 cancelled，实际 %+v", j)
	}
}
