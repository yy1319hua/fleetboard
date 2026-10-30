package upgrade

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// stubEnv 把包级可注入点换成测试替身，返回捕获的命令行。
func stubEnv(t *testing.T, systemdRunExists bool) *captured {
	t.Helper()
	c := &captured{}
	oldExec, oldLook, oldNow := execCommand, lookPath, now
	t.Cleanup(func() { execCommand, lookPath, now = oldExec, oldLook, oldNow })

	if systemdRunExists {
		lookPath = func(string) (string, error) { return "/usr/bin/systemd-run", nil }
	} else {
		lookPath = func(string) (string, error) { return "", errors.New("not found") }
	}
	execCommand = func(_ context.Context, name string, args ...string) *exec.Cmd {
		c.name = name
		c.args = args
		// 用 true 冒充 systemd-run：Run() 返回成功，也不会有真实副作用
		return exec.Command("true")
	}
	return c
}

type captured struct {
	mu   sync.Mutex
	name string
	args []string
}

func (c *captured) has(sub string) bool {
	for _, a := range c.args {
		if a == sub {
			return true
		}
	}
	return false
}

func (c *captured) joined() string { return strings.Join(c.args, " ") }

func tempCfg(t *testing.T) Config {
	t.Helper()
	dir := t.TempDir()
	return Config{
		Dir:     dir,
		BaseDir: "/opt/fleetboard",
		Version: "v0.2.2",
		Enabled: true,
	}
}

// writeStateFile 直接落一份状态文件，模拟脚本/上一次运行留下的现场。
func writeStateFile(t *testing.T, dir string, s Snapshot) {
	t.Helper()
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "upgrade-state.json"), b, 0o600); err != nil {
		t.Fatalf("写状态文件: %v", err)
	}
}

func TestSnapshotMissingFileIsIdle(t *testing.T) {
	m := NewManager(tempCfg(t))
	snap := m.Snapshot()
	if snap.State != StateIdle {
		t.Fatalf("状态文件缺失应为 idle，实际 %q", snap.State)
	}
	if snap.LogPath == "" {
		t.Error("idle 也应给出日志路径，前端要展示入口")
	}
}

func TestSnapshotCorruptJSONIsIdle(t *testing.T) {
	cfg := tempCfg(t)
	if err := os.WriteFile(filepath.Join(cfg.Dir, "upgrade-state.json"), []byte("{断掉的 JSON"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := NewManager(cfg).Snapshot(); got.State != StateIdle {
		t.Fatalf("损坏 JSON 应为 idle，实际 %q", got.State)
	}
}

func TestSnapshotReadsFields(t *testing.T) {
	cfg := tempCfg(t)
	ts := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	writeStateFile(t, cfg.Dir, Snapshot{
		State: StateHealthCheck, PhaseText: "健康检查", From: "v0.2.2", To: "v0.2.3",
		StartedAt: ts, UpdatedAt: ts, OpID: "op-1",
	})

	snap := NewManager(cfg).Snapshot()
	if snap.State != StateHealthCheck || snap.To != "v0.2.3" || snap.OpID != "op-1" {
		t.Fatalf("字段未正确解析: %+v", snap)
	}
	if !snap.StartedAt.Equal(ts) {
		t.Errorf("started_at=%v want %v", snap.StartedAt, ts)
	}
}

func TestLogTail(t *testing.T) {
	cfg := tempCfg(t)
	m := NewManager(cfg)

	if got := m.LogTail(10); got != nil {
		t.Fatalf("日志不存在应返回 nil，实际 %v", got)
	}
	if got := m.LogTail(0); got != nil {
		t.Fatalf("n<=0 应返回 nil，实际 %v", got)
	}

	body := "line1\nline2\nline3\n"
	if err := os.WriteFile(filepath.Join(cfg.Dir, "upgrade.log"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	got := m.LogTail(2)
	if len(got) != 2 || got[0] != "line2" || got[1] != "line3" {
		t.Fatalf("末 2 行错误: %v", got)
	}
	if all := m.LogTail(99); len(all) != 3 {
		t.Fatalf("行数应为 3，实际 %v", all)
	}
}

func TestStartBusyWhenInProgress(t *testing.T) {
	stubEnv(t, true)
	cfg := tempCfg(t)
	// 正在进行中：非终态 + started_at 在 30 分钟内
	writeStateFile(t, cfg.Dir, Snapshot{State: StateReplacing, StartedAt: time.Now().Add(-time.Minute), To: "v0.2.3", OpID: "op-1"})

	err := NewManager(cfg).Start("v0.2.3", "op-2")
	if !errors.Is(err, ErrBusy) {
		t.Fatalf("应为 ErrBusy，实际 %v", err)
	}
}

func TestStartIgnoresStaleInProgressState(t *testing.T) {
	c := stubEnv(t, true)
	cfg := tempCfg(t)
	// 31 分钟前的"进行中"是历史残留（机器重启过），不能被永久挡住
	writeStateFile(t, cfg.Dir, Snapshot{State: StateReplacing, StartedAt: time.Now().Add(-31 * time.Minute), To: "v0.2.3", OpID: "op-1"})

	if err := NewManager(cfg).Start("v0.2.3", "op-2"); err != nil {
		t.Fatalf("过期进行中态应允许新请求: %v", err)
	}
	if c.name != "systemd-run" {
		t.Fatalf("应调用 systemd-run，实际 %q", c.name)
	}
}

func TestStartDisabledWithoutSystemdRun(t *testing.T) {
	stubEnv(t, false)
	m := NewManager(tempCfg(t))
	if m.Enabled() {
		t.Fatal("没有 systemd-run 时 Enabled() 必须为 false")
	}
	if err := m.Start("v0.2.3", "op-1"); !errors.Is(err, ErrDisabled) {
		t.Fatalf("应为 ErrDisabled，实际 %v", err)
	}
}

func TestStartDisabledByConfig(t *testing.T) {
	stubEnv(t, true)
	cfg := tempCfg(t)
	cfg.Enabled = false
	if err := NewManager(cfg).Start("v0.2.3", "op-1"); !errors.Is(err, ErrDisabled) {
		t.Fatalf("开关关闭应为 ErrDisabled，实际 %v", err)
	}
}

func TestStartRejectsInvalidTarget(t *testing.T) {
	stubEnv(t, true)
	cfg := tempCfg(t)
	// 版本号会进 systemd-run 的命令行，字符集必须收紧，防注入
	if err := NewManager(cfg).Start("v1; rm -rf /", "op-1"); err == nil {
		t.Fatal("非法目标版本必须报错")
	}
	if err := NewManager(cfg).Start("v0.2.3", ""); err == nil {
		t.Fatal("缺 opID 必须报错")
	}
}

func TestStartInvokesSystemdRunWithSandboxPaths(t *testing.T) {
	c := stubEnv(t, true)
	cfg := tempCfg(t)
	m := NewManager(cfg)

	if err := m.Start("v0.2.3", "op-42"); err != nil {
		t.Fatalf("Start: %v", err)
	}

	// systemd-run 参数契约：独立 unit + 自动回收 + 非阻塞 + 显式放行两个写路径
	for _, want := range []string{"--collect", "--no-block"} {
		if !c.has(want) {
			t.Errorf("缺少参数 %s：%v", want, c.args)
		}
	}
	joined := c.joined()
	for _, want := range []string{
		"--unit=fleetboard-upgrade-",
		"ReadWritePaths=" + cfg.BaseDir,
		"ReadWritePaths=" + cfg.Dir,
		"sleep 2;",
		"--target 'v0.2.3'",
		"--from 'v0.2.2'",
		"--op-id 'op-42'",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("命令行缺少 %q：%s", want, joined)
		}
	}

	// 脚本被展开成 0700，且内容与内嵌版本一致
	script := filepath.Join(cfg.Dir, "upgrade-run.sh")
	fi, err := os.Stat(script)
	if err != nil {
		t.Fatalf("脚本未展开: %v", err)
	}
	if fi.Mode().Perm() != 0o700 {
		t.Errorf("脚本权限=%v want 0700", fi.Mode().Perm())
	}
	if !strings.Contains(joined, script) {
		t.Errorf("命令行应使用展开后的脚本路径 %s：%s", script, joined)
	}

	// 状态落成 requested，From/To/OpID 齐全
	snap := m.Snapshot()
	if snap.State != StateRequested || snap.To != "v0.2.3" || snap.From != "v0.2.2" || snap.OpID != "op-42" {
		t.Fatalf("requested 状态不对: %+v", snap)
	}
}

func TestExpandScriptRewritesOnDrift(t *testing.T) {
	stubEnv(t, true)
	cfg := tempCfg(t)
	script := filepath.Join(cfg.Dir, "upgrade-run.sh")
	// 上一次残留的旧脚本（内容不同）必须被覆盖，否则升级器与二进制不同版本
	if err := os.WriteFile(script, []byte("#!/bin/bash\necho old\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	m := NewManager(cfg)
	if _, err := m.expandScript(); err != nil {
		t.Fatalf("expandScript: %v", err)
	}
	b, err := os.ReadFile(script)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "echo old") {
		t.Fatal("内容漂移的脚本没有被重写")
	}
	// 再展开一次应命中"内容一致"快路径且不报错
	if _, err := m.expandScript(); err != nil {
		t.Fatalf("二次 expandScript: %v", err)
	}
}

func TestStartBusyWhenLockHeld(t *testing.T) {
	stubEnv(t, true)
	cfg := tempCfg(t)
	m := NewManager(cfg)

	// 模拟 upgrade.sh 正持有 flock（脚本从开头一直持到结束）
	f, err := os.OpenFile(filepath.Join(cfg.Dir, "upgrade.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("测试自身拿锁失败: %v", err)
	}

	if err := m.Start("v0.2.3", "op-1"); !errors.Is(err, ErrBusy) {
		t.Fatalf("锁被占用应返回 ErrBusy，实际 %v", err)
	}
}

func TestReconcileDoneWhenVersionMatches(t *testing.T) {
	stubEnv(t, true)
	cfg := tempCfg(t) // 当前版本 v0.2.2
	writeStateFile(t, cfg.Dir, Snapshot{
		State: StateHealthCheck, From: "v0.2.1", To: "v0.2.2",
		StartedAt: time.Now().Add(-time.Minute), OpID: "op-9",
	})

	snap, changed := NewManager(cfg).Reconcile()
	if !changed {
		t.Fatal("进行中态必须被改写")
	}
	if snap.State != StateDone {
		t.Fatalf("目标版本已生效应为 done，实际 %q", snap.State)
	}
	if snap.OpID != "op-9" || snap.From != "v0.2.1" {
		t.Errorf("对账不应丢字段: %+v", snap)
	}
	// 落盘也要是 done，App 轮询读的是文件
	if got := NewManager(cfg).Snapshot(); got.State != StateDone {
		t.Fatalf("状态文件未更新为 done：%q", got.State)
	}
}

func TestReconcileInterruptedWhenVersionDiffers(t *testing.T) {
	stubEnv(t, true)
	cfg := tempCfg(t) // 当前版本 v0.2.2，目标 v0.2.3 → 没升上去
	writeStateFile(t, cfg.Dir, Snapshot{
		State: StateReplacing, From: "v0.2.2", To: "v0.2.3", OpID: "op-10",
	})

	snap, changed := NewManager(cfg).Reconcile()
	if !changed || snap.State != StateInterrupted {
		t.Fatalf("版本不符应为 interrupted，实际 %q changed=%v", snap.State, changed)
	}
	if snap.ErrorCode != "interrupted" {
		t.Errorf("error_code=%q", snap.ErrorCode)
	}
	if !strings.Contains(snap.PhaseText, "v0.2.3") {
		t.Errorf("phase_text 应说明目标版本: %q", snap.PhaseText)
	}
}

func TestReconcileNoopOnTerminalState(t *testing.T) {
	stubEnv(t, true)
	for _, st := range []string{StateIdle, StateDone, StateFailed, StateRolledBack, StateInterrupted} {
		cfg := tempCfg(t)
		writeStateFile(t, cfg.Dir, Snapshot{State: st, To: "v0.2.3", OpID: "op-x"})
		snap, changed := NewManager(cfg).Reconcile()
		if changed {
			t.Errorf("终态 %q 不应被改写", st)
		}
		if snap.State != st {
			t.Errorf("终态 %q 被改成了 %q", st, snap.State)
		}
	}
	// 状态文件缺失也不能被改写成 interrupted
	cfg := tempCfg(t)
	snap, changed := NewManager(cfg).Reconcile()
	if changed || snap.State != StateIdle {
		t.Fatalf("无状态文件应为 idle 且不改写，实际 %q changed=%v", snap.State, changed)
	}
}

func TestScriptEmbedded(t *testing.T) {
	if len(scriptBytes) < 1000 {
		t.Fatalf("内嵌脚本异常（%d 字节）——是否忘了 make sync-upgrade", len(scriptBytes))
	}
	if !strings.HasPrefix(string(scriptBytes), "#!/usr/bin/env bash") {
		t.Fatal("内嵌脚本缺 shebang")
	}
	if ScriptSHA256() == "" {
		t.Fatal("ScriptSHA256 为空")
	}
}

// TestEmbedScriptMatchesSource 守住「源脚本与内嵌副本一致」。
//
// deploy/upgrade.sh 是唯一源，internal/upgrade/upgrade.sh 是 go:embed 副本，
// 由 make sync-upgrade 同步。但 CI 直接跑 `go test ./...`（不经 make），
// 于是「改了 deploy 忘记同步副本」在 CI 里完全看不出来——二进制里嵌的还是旧脚本，
// 线上自更新会静默沿用旧逻辑。v0.4.4 修复期真实发生过：deploy 已改，embed 仍是旧的。
func TestEmbedScriptMatchesSource(t *testing.T) {
	path := filepath.Join("..", "..", "deploy", "upgrade.sh")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("跳过：读不到源脚本 %s（%v）", path, err)
	}
	if string(src) != string(scriptBytes) {
		t.Fatalf("内嵌脚本与 %s 不一致（源 %d 字节 / 内嵌 %d 字节）——请运行 make sync-upgrade",
			path, len(src), len(scriptBytes))
	}
}
