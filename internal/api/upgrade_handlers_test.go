package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/upgrade"
)

// fakeUpgradeManager 是 UpgradeManager 的假实现：
// 生产环境的真实编排要动 systemd，测试只需观察 api 层怎么用这些返回值。
type fakeUpgradeManager struct {
	snap     upgrade.Snapshot
	logTail  []string
	startErr error
	enabled  bool

	starts       int
	lastTarget   string
	lastOpID     string
	logTailAsked int
}

func (f *fakeUpgradeManager) Snapshot() upgrade.Snapshot { return f.snap }
func (f *fakeUpgradeManager) Enabled() bool              { return f.enabled }
func (f *fakeUpgradeManager) Reconcile() (upgrade.Snapshot, bool) {
	return f.snap, false
}

// LogTail 模拟真实编排层的「取末 n 行」语义，并记下 api 层请求的行数。
func (f *fakeUpgradeManager) LogTail(n int) []string {
	f.logTailAsked = n
	if n <= 0 || n > len(f.logTail) {
		return f.logTail
	}
	return f.logTail[len(f.logTail)-n:]
}

func (f *fakeUpgradeManager) Start(target, opID string) error {
	f.starts++
	f.lastTarget, f.lastOpID = target, opID
	if f.startErr != nil {
		return f.startErr
	}
	f.snap.State = "preparing"
	f.snap.To = target
	f.snap.LogPath = "/var/lib/fleetboard/upgrade.log"
	return nil
}

// fakeVersionSource 固定返回一个 tag，用于绕开 GitHub 外呼。
type fakeVersionSource struct {
	tag   string
	err   error
	calls int
}

func (f *fakeVersionSource) Latest(_ context.Context) (string, error) {
	f.calls++
	return f.tag, f.err
}

// newUpgradeTestServer 起一个带鉴权与真实 DB 的引擎，自更新依赖全部注入。
func newUpgradeTestServer(t *testing.T, m *fakeUpgradeManager, src versionSource, enabled bool, envCheck func() string) (*gin.Engine, *sql.DB) {
	t.Helper()
	return newUpgradeTestServerVersion(t, m, src, enabled, envCheck, "v0.3.2")
}

func newUpgradeTestServerVersion(t *testing.T, m *fakeUpgradeManager, src versionSource, enabled bool, envCheck func() string, version string) (*gin.Engine, *sql.DB) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	if _, err := db.EnsureAdmin(d, "admin", "pass123"); err != nil {
		t.Fatalf("EnsureAdmin: %v", err)
	}
	if envCheck == nil {
		envCheck = func() string { return "" }
	}
	gin.SetMode(gin.TestMode)
	r := NewRouter(RouterOptions{
		Version:   version,
		DB:        d,
		JWTSecret: "test-secret",
		MasterKey: "test-master",
		Upgrade: &UpgradeWiring{
			Manager:  m,
			Enabled:  enabled,
			BaseDir:  t.TempDir(),
			EnvCheck: envCheck,
			Source:   src,
		},
	})
	return r, d
}

// upgradeRequest 发一次带自定义头的请求（幂等头/审计头靠它带进去）。
func upgradeRequest(t *testing.T, r http.Handler, method, path string, body any, token string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	var req *http.Request
	if body != nil {
		b, _ := json.Marshal(body)
		req = httptest.NewRequest(method, path, bytes.NewReader(b))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func decodeUpgradeInfo(t *testing.T, w *httptest.ResponseRecorder) upgradeInfo {
	t.Helper()
	var resp struct {
		Code int         `json:"code"`
		Data upgradeInfo `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应: %v (%s)", err, w.Body)
	}
	return resp.Data
}

func decodeUpgradeStatus(t *testing.T, w *httptest.ResponseRecorder) upgradeStatusInfo {
	t.Helper()
	var resp struct {
		Data upgradeStatusInfo `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应: %v (%s)", err, w.Body)
	}
	return resp.Data
}

// 开关关闭：GET 仍 200 并解释原因（App 要能展示），POST/status 一律 404（不泄露能力）。
func TestSystemUpgradeDisabled(t *testing.T) {
	src := &fakeVersionSource{tag: "v0.4.0"}
	r, _ := newUpgradeTestServer(t, &fakeUpgradeManager{}, src, false, nil)
	tokens := loginTokens(t, r)

	w := upgradeRequest(t, r, http.MethodGet, "/api/system/upgrade", nil, tokens.AccessToken, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("GET 应 200（关闭也要能解释原因）: %d", w.Code)
	}
	info := decodeUpgradeInfo(t, w)
	if info.UpgradeEnabled || info.CanUpgrade {
		t.Errorf("关闭时不应可升级: %+v", info)
	}
	if info.Reason != "本实例未开启面板自更新" {
		t.Errorf("reason=%q", info.Reason)
	}
	if info.CurrentVersion != "v0.3.2" || info.LatestVersion != "v0.3.2" {
		t.Errorf("关闭时不应外呼查版本: %+v", info)
	}
	if info.Last != nil {
		t.Errorf("无历史时 last 应为 null: %+v", info.Last)
	}
	if src.calls != 0 {
		t.Errorf("关闭时不应请求 GitHub, calls=%d", src.calls)
	}

	w = upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade", map[string]string{"password": "pass123"}, tokens.AccessToken, map[string]string{"X-Client-Op-Id": "op-1"})
	if w.Code != http.StatusNotFound {
		t.Errorf("POST 关闭应 404（不是 403）: %d", w.Code)
	}
	w = upgradeRequest(t, r, http.MethodGet, "/api/system/upgrade/status", nil, tokens.AccessToken, nil)
	if w.Code != http.StatusNotFound {
		t.Errorf("status 关闭应 404: %d", w.Code)
	}
}

// 开关开 + 环境满足 + 有新版 → can_upgrade=true；各种不满足逐条给出中文 reason。
func TestSystemUpgradeInfoReasonMatrix(t *testing.T) {
	cases := []struct {
		name    string
		version string
		src     *fakeVersionSource
		snap    upgrade.Snapshot
		env     func() string
		wantCan bool
		wantWhy string
	}{
		{
			name:    "有新版",
			src:     &fakeVersionSource{tag: "v0.4.0"},
			wantCan: true,
		},
		{
			name:    "已是最新",
			src:     &fakeVersionSource{tag: "v0.3.2"},
			wantWhy: "当前已是最新版本",
		},
		{
			name:    "GitHub不可达",
			src:     &fakeVersionSource{err: errFakeUpstream},
			wantWhy: "无法获取最新版本",
		},
		{
			name:    "环境不满足",
			src:     &fakeVersionSource{tag: "v0.4.0"},
			env:     func() string { return "运行环境不满足：未找到 systemctl" },
			wantWhy: "运行环境不满足：未找到 systemctl",
		},
		{
			name:    "升级进行中",
			src:     &fakeVersionSource{tag: "v0.4.0"},
			snap:    upgrade.Snapshot{State: "replacing", StartedAt: time.Now().Add(-time.Minute)},
			wantWhy: "已有升级任务在进行",
		},
		{
			name:    "陈旧的进行中状态不算忙",
			src:     &fakeVersionSource{tag: "v0.4.0"},
			snap:    upgrade.Snapshot{State: "replacing", StartedAt: time.Now().Add(-2 * time.Hour)},
			wantCan: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := &fakeUpgradeManager{snap: c.snap, enabled: true}
			r, _ := newUpgradeTestServer(t, m, c.src, true, c.env)
			tokens := loginTokens(t, r)

			w := upgradeRequest(t, r, http.MethodGet, "/api/system/upgrade", nil, tokens.AccessToken, nil)
			if w.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", w.Code, w.Body)
			}
			info := decodeUpgradeInfo(t, w)
			if info.CanUpgrade != c.wantCan {
				t.Errorf("can_upgrade=%v, want %v", info.CanUpgrade, c.wantCan)
			}
			if info.Reason != c.wantWhy {
				t.Errorf("reason=%q, want %q", info.Reason, c.wantWhy)
			}
			if c.wantCan {
				if info.LatestVersion != "v0.4.0" || info.CurrentVersion != "v0.3.2" {
					t.Errorf("版本展示不符: %+v", info)
				}
			}
			// GitHub 失败时 latest 必须回退为 current，不能让 App 显示空版本
			if c.wantWhy == "无法获取最新版本" && info.LatestVersion != "v0.3.2" {
				t.Errorf("失败应回退 latest=current, got %q", info.LatestVersion)
			}
		})
	}
}

// dev 构建没有可比较的版本号：宁可说「无法判断」也不谎报有新版。
func TestSystemUpgradeInfoDevBuild(t *testing.T) {
	src := &fakeVersionSource{tag: "v0.4.0"}
	m := &fakeUpgradeManager{enabled: true}
	r, _ := newUpgradeTestServerVersion(t, m, src, true, nil, "dev")
	tokens := loginTokens(t, r)

	w := upgradeRequest(t, r, http.MethodGet, "/api/system/upgrade", nil, tokens.AccessToken, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d", w.Code)
	}
	info := decodeUpgradeInfo(t, w)
	if info.CanUpgrade {
		t.Error("dev 构建不应被判为可升级")
	}
	if !strings.Contains(info.Reason, "当前版本未知") {
		t.Errorf("reason=%q", info.Reason)
	}
	if src.calls != 0 {
		t.Errorf("dev 构建不该查 GitHub, calls=%d", src.calls)
	}
}

// 触发成功：202 + Location + 快照载荷 + 历史落库 + 专用审计。
func TestTriggerUpgradeAccepted(t *testing.T) {
	src := &fakeVersionSource{tag: "v0.4.0"}
	m := &fakeUpgradeManager{enabled: true, snap: upgrade.Snapshot{State: "idle", From: "v0.3.2"}}
	r, d := newUpgradeTestServer(t, m, src, true, nil)
	tokens := loginTokens(t, r)

	w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
		map[string]string{"password": "pass123", "target_version": "v0.4.0"},
		tokens.AccessToken, map[string]string{"X-Client-Op-Id": "op-42"})
	if w.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	if loc := w.Header().Get("Location"); loc != "/api/system/upgrade/status" {
		t.Errorf("Location=%q", loc)
	}
	if m.starts != 1 || m.lastTarget != "v0.4.0" || m.lastOpID != "op-42" {
		t.Errorf("编排层调用不符: %+v", m)
	}
	st := decodeUpgradeStatus(t, w)
	if st.State != "preparing" || st.LogTail == nil {
		t.Errorf("202 应带当前快照（log_tail 至少是空数组）: %+v", st)
	}

	// 历史表：一条 in_progress，from/to 与触发者正确
	list, err := db.LatestUpgrades(d, 5)
	if err != nil {
		t.Fatalf("LatestUpgrades: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("历史记录数=%d, want 1", len(list))
	}
	rec := list[0]
	if rec.FromVersion != "v0.3.2" || rec.ToVersion != "v0.4.0" || rec.Status != db.UpgradeInProgress {
		t.Errorf("历史记录不符: %+v", rec)
	}
	if rec.TriggeredBy == nil || *rec.TriggeredBy == 0 {
		t.Errorf("triggered_by 应记录当前用户: %+v", rec)
	}
	if rec.LogPath == "" {
		t.Error("log_path 应从快照回填")
	}

	// 审计：专用动作 system.upgrade.request，detail 含 from/to/opId
	logs, err := db.ListAudit(d, 20)
	if err != nil {
		t.Fatalf("ListAudit: %v", err)
	}
	var found bool
	for _, l := range logs {
		if l.Action == "system.upgrade.request" {
			found = true
			for _, want := range []string{"from=v0.3.2", "to=v0.4.0", "opId=op-42"} {
				if !strings.Contains(l.Detail, want) {
					t.Errorf("审计 detail 缺 %q: %s", want, l.Detail)
				}
			}
		}
	}
	if !found {
		t.Error("缺少 system.upgrade.request 审计")
	}
}

// 触发失败矩阵：缺 opId / 缺密码 / 密码错 / 退避 / 环境不满足 / 升级中 / 编排返回忙。
func TestTriggerUpgradeRejections(t *testing.T) {
	src := &fakeVersionSource{tag: "v0.4.0"}
	m := &fakeUpgradeManager{enabled: true}
	r, _ := newUpgradeTestServer(t, m, src, true, nil)
	tokens := loginTokens(t, r)
	okHeaders := map[string]string{"X-Client-Op-Id": "op-x"}

	w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
		map[string]string{"password": "pass123"}, tokens.AccessToken, nil)
	if w.Code != http.StatusBadRequest {
		t.Errorf("缺 opId 应 400: %d", w.Code)
	}

	w = upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
		map[string]string{"target_version": "v0.4.0"}, tokens.AccessToken, okHeaders)
	if w.Code != http.StatusBadRequest {
		t.Errorf("缺密码应 400: %d", w.Code)
	}

	w = upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
		map[string]string{"password": "wrong", "target_version": "v0.4.0"}, tokens.AccessToken, okHeaders)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("密码错应 401: %d", w.Code)
	}

	// 连续 5 次错 → 退避生效：此时即使密码正确也必须被拒（说明压根没查库校验）
	for i := 0; i < passwordFailLimit; i++ {
		_ = upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
			map[string]string{"password": "wrong", "target_version": "v0.4.0"}, tokens.AccessToken, okHeaders)
	}
	w = upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
		map[string]string{"password": "pass123", "target_version": "v0.4.0"}, tokens.AccessToken, okHeaders)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("退避期内应 401: %d", w.Code)
	}
	if !strings.Contains(w.Body.String(), "次数过多") {
		t.Errorf("退避文案应说明原因: %s", w.Body)
	}
	if m.starts != 0 {
		t.Errorf("被拒的请求不应触发编排, starts=%d", m.starts)
	}
}

// 环境不满足 / 升级中 / 目标版本过低 → 409，且都不触发编排层。
func TestTriggerUpgradeConflicts(t *testing.T) {
	src := &fakeVersionSource{tag: "v0.4.0"}
	headers := map[string]string{"X-Client-Op-Id": "op-y"}
	body := map[string]string{"password": "pass123"}

	t.Run("环境不满足", func(t *testing.T) {
		m := &fakeUpgradeManager{enabled: true}
		r, _ := newUpgradeTestServer(t, m, src, true, func() string { return "运行环境不满足：未找到 systemctl" })
		tokens := loginTokens(t, r)
		w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade", body, tokens.AccessToken, headers)
		if w.Code != http.StatusConflict {
			t.Fatalf("应 409: %d %s", w.Code, w.Body)
		}
		if !strings.Contains(w.Body.String(), "运行环境不满足") {
			t.Errorf("应回中文原因: %s", w.Body)
		}
		if m.starts != 0 {
			t.Error("环境不满足不应触发编排")
		}
	})

	t.Run("升级进行中", func(t *testing.T) {
		m := &fakeUpgradeManager{enabled: true, snap: upgrade.Snapshot{State: "replacing"}}
		r, _ := newUpgradeTestServer(t, m, src, true, nil)
		tokens := loginTokens(t, r)
		w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade", body, tokens.AccessToken, headers)
		if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "已有升级任务在进行") {
			t.Fatalf("应 409 且说明进行中: %d %s", w.Code, w.Body)
		}
	})

	t.Run("目标版本不高于当前", func(t *testing.T) {
		m := &fakeUpgradeManager{enabled: true}
		r, _ := newUpgradeTestServer(t, m, src, true, nil)
		tokens := loginTokens(t, r)
		w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
			map[string]string{"password": "pass123", "target_version": "v0.3.1"}, tokens.AccessToken, headers)
		if w.Code != http.StatusConflict {
			t.Fatalf("应 409: %d %s", w.Code, w.Body)
		}
	})

	t.Run("编排返回忙", func(t *testing.T) {
		m := &fakeUpgradeManager{enabled: true, startErr: upgrade.ErrBusy}
		r, d := newUpgradeTestServer(t, m, src, true, nil)
		tokens := loginTokens(t, r)
		w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade", body, tokens.AccessToken, headers)
		if w.Code != http.StatusConflict {
			t.Fatalf("ErrBusy 应 409: %d %s", w.Code, w.Body)
		}
		// 失败的历史记录要收敛到 failed，不能留 in_progress 卡住后续触发
		list, _ := db.LatestUpgrades(d, 1)
		if len(list) != 1 || list[0].Status != db.UpgradeFailed || list[0].ErrorCode != "busy" {
			t.Errorf("失败记录未收敛: %+v", list)
		}
		// 失败也要留专用审计：危险操作被尝试过必须可追溯
		logs, _ := db.ListAudit(d, 10)
		var audited bool
		for _, l := range logs {
			if l.Action == "system.upgrade.request" && l.Result == "fail" {
				audited = true
			}
		}
		if !audited {
			t.Error("失败的触发也应写 system.upgrade.request 审计")
		}
	})

	t.Run("编排返回未启用", func(t *testing.T) {
		m := &fakeUpgradeManager{enabled: true, startErr: upgrade.ErrDisabled}
		r, _ := newUpgradeTestServer(t, m, src, true, nil)
		tokens := loginTokens(t, r)
		w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade", body, tokens.AccessToken, headers)
		if w.Code != http.StatusNotFound {
			t.Fatalf("ErrDisabled 应按未开启处理(404): %d %s", w.Code, w.Body)
		}
	})
}

// 省略 target_version 时用 GitHub 的最新版本；拿不到就 409 并要求显式指定。
func TestTriggerUpgradeTargetFallback(t *testing.T) {
	m := &fakeUpgradeManager{enabled: true}
	src := &fakeVersionSource{tag: "v0.4.0"}
	r, _ := newUpgradeTestServer(t, m, src, true, nil)
	tokens := loginTokens(t, r)

	w := upgradeRequest(t, r, http.MethodPost, "/api/system/upgrade",
		map[string]string{"password": "pass123"}, tokens.AccessToken,
		map[string]string{"X-Client-Op-Id": "op-z"})
	if w.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	if m.lastTarget != "v0.4.0" {
		t.Errorf("应回落到 latest, got %q", m.lastTarget)
	}

	m2 := &fakeUpgradeManager{enabled: true}
	r2, _ := newUpgradeTestServer(t, m2, &fakeVersionSource{err: errFakeUpstream}, true, nil)
	tokens2 := loginTokens(t, r2)
	w = upgradeRequest(t, r2, http.MethodPost, "/api/system/upgrade",
		map[string]string{"password": "pass123"}, tokens2.AccessToken,
		map[string]string{"X-Client-Op-Id": "op-w"})
	if w.Code != http.StatusConflict {
		t.Errorf("无法获取 latest 时应 409: %d %s", w.Code, w.Body)
	}
}

// status：阶段 + 日志尾（截断到 20 行）；终态轮询顺带补写历史表。
func TestUpgradeStatusAndTerminalSync(t *testing.T) {
	tail := make([]string, 30)
	for i := range tail {
		tail[i] = "line"
	}
	m := &fakeUpgradeManager{
		enabled: true,
		logTail: tail,
		snap: upgrade.Snapshot{
			State:     "replacing",
			PhaseText: "正在替换文件",
			From:      "v0.3.2",
			To:        "v0.4.0",
		},
	}
	r, d := newUpgradeTestServer(t, m, &fakeVersionSource{tag: "v0.4.0"}, true, nil)
	tokens := loginTokens(t, r)

	// 先造一条在途记录，等会儿由终态轮询收尾
	recID, err := db.InsertUpgradeStart(d, "v0.3.2", "v0.4.0", 1, "")
	if err != nil {
		t.Fatalf("InsertUpgradeStart: %v", err)
	}

	w := upgradeRequest(t, r, http.MethodGet, "/api/system/upgrade/status", nil, tokens.AccessToken, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body)
	}
	st := decodeUpgradeStatus(t, w)
	if st.State != "replacing" || st.PhaseText != "正在替换文件" {
		t.Errorf("阶段信息不符: %+v", st)
	}
	if st.From != "v0.3.2" || st.To != "v0.4.0" {
		t.Errorf("from/to 不符: %+v", st)
	}
	if m.logTailAsked != 20 {
		t.Errorf("api 层应请求末 20 行, got %d", m.logTailAsked)
	}
	if len(st.LogTail) != 20 {
		t.Errorf("log_tail 截断到 20 行, got %d", len(st.LogTail))
	}
	// 在途状态不应改动历史
	if rec, _ := db.LatestInProgressUpgrade(d); rec == nil || rec.ID != recID {
		t.Error("在途状态不应收尾历史记录")
	}

	// 编排层进入终态 → 轮询补写历史
	m.snap.State = "done"
	m.snap.StartedAt = time.Now().Add(-3 * time.Second)
	m.snap.UpdatedAt = time.Now()
	w = upgradeRequest(t, r, http.MethodGet, "/api/system/upgrade/status", nil, tokens.AccessToken, nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d", w.Code)
	}
	if rec, _ := db.LatestInProgressUpgrade(d); rec != nil {
		t.Errorf("终态后不应残留 in_progress: %+v", rec)
	}
	list, _ := db.LatestUpgrades(d, 1)
	if list[0].Status != db.UpgradeDone {
		t.Errorf("历史应补写为 done: %+v", list[0])
	}
	if list[0].DurationMs < 2000 {
		t.Errorf("耗时应来自快照时间差, got %d", list[0].DurationMs)
	}
}

// 空闲态的 status：state=idle，from/to 用最近一条历史兜底，log_tail 为 []。
func TestUpgradeStatusIdle(t *testing.T) {
	m := &fakeUpgradeManager{enabled: true, snap: upgrade.Snapshot{State: "idle"}}
	r, d := newUpgradeTestServer(t, m, &fakeVersionSource{tag: "v0.4.0"}, true, nil)
	tokens := loginTokens(t, r)

	if _, err := db.InsertUpgradeStart(d, "v0.3.1", "v0.3.2", 1, ""); err != nil {
		t.Fatalf("InsertUpgradeStart: %v", err)
	}

	w := upgradeRequest(t, r, http.MethodGet, "/api/system/upgrade/status", nil, tokens.AccessToken, nil)
	st := decodeUpgradeStatus(t, w)
	if st.State != "idle" {
		t.Errorf("state=%q", st.State)
	}
	if st.From != "v0.3.1" || st.To != "v0.3.2" {
		t.Errorf("空闲时应用历史兜底 from/to: %+v", st)
	}
	if st.LogTail == nil || len(st.LogTail) != 0 {
		t.Errorf("log_tail 应为空数组: %#v", st.LogTail)
	}
}

// 真实环境判定：临时目录里放 .env 后应判定通过（systemctl 缺失时原因里会点名它）。
func TestUpgradeEnvReason(t *testing.T) {
	dir := t.TempDir()
	if reason := upgradeEnvReason(dir); reason == "" || !strings.Contains(reason, ".env") {
		t.Errorf("缺 .env 应说明原因: %q", reason)
	}
	if UpgradeEnvReady(dir) {
		t.Error("缺 .env 不应就绪")
	}

	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("KEY=x\n"), 0o600); err != nil {
		t.Fatalf("写 .env: %v", err)
	}
	if reason := upgradeEnvReason(dir); reason != "" {
		t.Logf("本机缺少 systemctl，按预期给出原因: %s", reason)
	}
}

// errFakeUpstream 模拟 GitHub 外呼失败。
var errFakeUpstream = errors.New("fake upstream failure")
