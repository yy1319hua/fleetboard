// Package upgrade 实现"面板自我升级"的状态机与执行入口。
//
// 设计要点（为什么不直接 exec 一个子进程）：
// fleetboard 由 systemd 以 Type=simple 托管，`systemctl stop` 会杀掉同一 cgroup 内的
// 所有进程。exec.Command 起的子进程、setsid、nohup、disown 都只换 session/进程组，
// 不换 cgroup，照样被连带杀死。因此升级进程必须跑在独立的 transient unit 里
// （systemd-run --unit=...），本包只负责：写状态、放脚本、提交 unit、读状态。
//
// 本包刻意不依赖 db：Reconcile 只把终态快照返回给调用方（main），由调用方落库，
// 这样状态机可以纯文件单测。
package upgrade

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// upgrade.sh 的**唯一源**是 deploy/upgrade.sh。
// 因为 go:embed 只能嵌入包目录内的文件，构建前由 Makefile 的 sync-upgrade 步骤把
// deploy/upgrade.sh 复制到这里（副本必须入库：CI 直接跑 `go test ./...`，不经 make）。
// 选这个方向（deploy → 包内副本）而不是反过来的理由：release.yml 打发布包时
// 也是从 deploy/ 取脚本给用户手工跑，deploy/ 才是运维可见的那一份，源放它那里不会漂。
//
//go:embed upgrade.sh
var scriptBytes []byte

// 状态取值。与 deploy/upgrade.sh 写出的 state 字段逐字一致。
const (
	StateIdle        = "idle"         // 没有升级记录（状态文件缺失/损坏也归到这里）
	StateRequested   = "requested"    // 后端已受理，unit 已提交
	StateVerifying   = "verifying"    // 取包/校验
	StateStopping    = "stopping"     // 停服
	StateBackingUp   = "backing_up"   // 备份数据库
	StateReplacing   = "replacing"    // 换二进制/前端
	StateStarting    = "starting"     // 起服务
	StateHealthCheck = "health_check" // 健康检查
	StateDone        = "done"         // 成功
	StateFailed      = "failed"       // 失败（能回滚的已回滚）
	StateRolledBack  = "rolled_back"  // 回滚执行中
	StateInterrupted = "interrupted"  // 进程中途消失，由 Reconcile 判定
)

// busyWindow 内的"进行中"状态会挡住新的升级请求；超过这个窗口视为历史残留
// （避免机器异常重启后状态文件永远把用户锁在 ErrBusy 里）。
const busyWindow = 30 * time.Minute

// Snapshot 是 upgrade-state.json 的镜像，也是后端/App 之间约定的稳定契约。
type Snapshot struct {
	State     string    `json:"state"`
	PhaseText string    `json:"phase_text"`
	From      string    `json:"from"`
	To        string    `json:"to"`
	ErrorCode string    `json:"error_code"`
	StartedAt time.Time `json:"started_at"`
	UpdatedAt time.Time `json:"updated_at"`
	LogPath   string    `json:"log_path"`
	OpID      string    `json:"op_id"`
}

// Config 是 Manager 的运行参数。
type Config struct {
	Dir     string // 状态与日志目录，通常 /var/lib/fleetboard
	BaseDir string // /opt/fleetboard
	Version string // 当前运行版本
	Enabled bool   // 环境是否满足自更新（配置开关 + systemd-run 存在）
}

// ErrBusy 表示已有升级在执行（状态非终态，或 flock 被占用）。
var ErrBusy = errors.New("upgrade in progress")

// ErrDisabled 表示当前环境不支持自更新（开关关闭或没有 systemd-run）。
var ErrDisabled = errors.New("upgrade disabled")

// 可注入点：单测替换，生产用默认实现。
var (
	execCommand = exec.CommandContext
	lookPath    = exec.LookPath
	now         = time.Now
)

// Manager 是无状态以外的唯一持有者：字段全部只读，方法可并发调用。
type Manager struct {
	cfg Config

	scriptMu sync.Mutex // 串行化脚本展开，避免两个请求同时写 upgrade-run.sh
}

// NewManager 构造 Manager。cfg.Dir 为空时所有文件操作会失败，调用方应保证非空。
func NewManager(cfg Config) *Manager {
	return &Manager{cfg: cfg}
}

// Enabled 报告当前环境是否允许自更新：开关打开 + 确实有 systemd-run。
// 没有 systemd-run 就没法脱离 cgroup，硬着头皮 exec 只会把自己一起杀掉。
func (m *Manager) Enabled() bool {
	if m == nil || !m.cfg.Enabled {
		return false
	}
	if strings.TrimSpace(m.cfg.Dir) == "" || strings.TrimSpace(m.cfg.BaseDir) == "" {
		return false
	}
	_, err := lookPath("systemd-run")
	return err == nil
}

// Snapshot 读状态文件。文件不存在、读失败、JSON 损坏一律返回 State=idle，
// **不返回 error**：面板首屏不该因为一个坏状态文件而报错。
func (m *Manager) Snapshot() Snapshot {
	snap := Snapshot{State: StateIdle, LogPath: m.logPath()}
	if m == nil || strings.TrimSpace(m.cfg.Dir) == "" {
		return snap
	}
	b, err := os.ReadFile(m.statePath())
	if err != nil {
		return snap
	}
	var got Snapshot
	if err := json.Unmarshal(b, &got); err != nil {
		return snap
	}
	if strings.TrimSpace(got.State) == "" {
		got.State = StateIdle
	}
	if got.LogPath == "" {
		got.LogPath = m.logPath()
	}
	return got
}

// LogTail 返回日志最后 n 行（只读文件尾部，避免整份日志读进内存）。
// 文件不存在返回 nil。
func (m *Manager) LogTail(n int) []string {
	if m == nil || n <= 0 || strings.TrimSpace(m.cfg.Dir) == "" {
		return nil
	}
	const maxRead = 256 << 10
	f, err := os.Open(m.logPath())
	if err != nil {
		return nil
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return nil
	}
	var off int64
	if st.Size() > maxRead {
		off = st.Size() - maxRead
	}
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		return nil
	}
	data, err := io.ReadAll(f)
	if err != nil || len(data) == 0 {
		return nil
	}

	text := strings.TrimRight(string(data), "\n")
	if text == "" {
		return nil
	}
	lines := strings.Split(text, "\n")
	// 从中间截断时首行多半是半行，丢掉避免误导
	if off > 0 && len(lines) > 1 {
		lines = lines[1:]
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}

// Start 提交一次升级。返回 nil 只代表"unit 已提交"，不代表升级成功——
// 后续进度要看 Snapshot()，或由 Reconcile 在重启后对账。
func (m *Manager) Start(targetVersion, opID string) error {
	if m == nil {
		return ErrDisabled
	}
	if err := m.ensureDir(); err != nil {
		return err
	}
	if !m.Enabled() {
		return ErrDisabled
	}
	if err := validToken("目标版本", targetVersion); err != nil {
		return err
	}
	if err := validToken("操作 ID", opID); err != nil {
		return err
	}

	// 已在进行中：状态非终态且 started_at 在 30 分钟内 → 直接挡回去，别开第二个 unit
	if snap := m.Snapshot(); !isTerminal(snap.State) {
		if snap.StartedAt.IsZero() || now().Sub(snap.StartedAt) < busyWindow {
			return ErrBusy
		}
	}

	// flock：与 upgrade.sh 共用 $DATA/upgrade.lock。脚本会持有整场升级，
	// 这里拿不到锁说明确实有升级在跑（或刚才的脚本还没退出）。
	unlock, err := m.lock()
	if err != nil {
		return ErrBusy
	}
	defer unlock()

	script, err := m.expandScript()
	if err != nil {
		return fmt.Errorf("展开升级脚本失败: %w", err)
	}

	ts := now().UTC()
	req := Snapshot{
		State:     StateRequested,
		PhaseText: "已受理升级请求，等待执行",
		From:      m.cfg.Version,
		To:        targetVersion,
		StartedAt: ts,
		UpdatedAt: ts,
		LogPath:   m.logPath(),
		OpID:      opID,
	}
	if err := m.writeState(req); err != nil {
		return fmt.Errorf("写状态文件失败: %w", err)
	}

	// 为什么交给 systemd-run：
	//   --unit=fleetboard-upgrade-<ts>  独立 unit ⇒ 独立 cgroup ⇒ `systemctl stop fleetboard` 不会连坐
	//   --collect   unit 退出后自动回收，不留 failed 残骸
	//   --no-block  只提交 job 不等待，HTTP 202 才能立刻返回
	//   -p ReadWritePaths=...  transient unit 不继承父 unit 的沙箱放宽，
	//               写 /opt/fleetboard（二进制、web-dist.d）与 /var/lib/fleetboard（状态、备份）
	//               必须显式放行，否则脚本写盘 EROFS。
	// 内层 bash -lc 的 `sleep 2` 是留给 HTTP 202 响应 flush 的时间：
	// 脚本一起来就会 systemctl stop，过早停服会让 App 收不到"已受理"。
	args := []string{
		"--unit=" + fmt.Sprintf("fleetboard-upgrade-%d", ts.Unix()),
		"--collect",
		"--no-block",
		"-p", "ReadWritePaths=" + m.cfg.BaseDir,
		"-p", "ReadWritePaths=" + m.cfg.Dir,
		"/bin/bash", "-lc",
		fmt.Sprintf("sleep 2; exec %s --target %s --from %s --op-id %s",
			shQuote(script), shQuote(targetVersion), shQuote(m.cfg.Version), shQuote(opID)),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if out, err := execCommand(ctx, "systemd-run", args...).CombinedOutput(); err != nil {
		fail := req
		fail.State = StateFailed
		fail.PhaseText = "提交升级任务失败（systemd-run 报错）"
		fail.ErrorCode = "systemd_run_failed"
		_ = m.writeState(fail)
		return fmt.Errorf("systemd-run 启动失败: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Reconcile 在进程启动时调用，用来收拾"升级进程把服务重启了但没来得及写终态"的烂尾场景。
// 返回的 bool 表示状态是否被改写——为 true 时调用方应把 snapshot 落库。
// 本方法不碰 DB（保持包可单测）。
func (m *Manager) Reconcile() (Snapshot, bool) {
	snap := m.Snapshot()
	if isTerminal(snap.State) {
		return snap, false
	}

	// 进程已经带着目标版本起来了 ⇒ 升级实际成功，只是最后一步没写
	if snap.To != "" && snap.To == m.cfg.Version {
		snap.State = StateDone
		snap.PhaseText = "升级已完成（重启后版本已生效）"
		snap.ErrorCode = ""
	} else {
		// 版本没变 / 变成了别的版本 ⇒ 中途被杀，例如机器重启、unit 被 kill
		snap.State = StateInterrupted
		snap.PhaseText = fmt.Sprintf("升级中断：当前版本 %s，目标版本 %s", orDash(m.cfg.Version), orDash(snap.To))
		snap.ErrorCode = "interrupted"
	}
	snap.UpdatedAt = now().UTC()
	snap.LogPath = m.logPath()
	if err := m.writeState(snap); err != nil {
		// 写不进去也要把内存态返回，让调用方至少能把 DB 标成终态
		return snap, true
	}
	return snap, true
}

// ───────────────────────────── 内部实现 ─────────────────────────────

func (m *Manager) statePath() string { return filepath.Join(m.cfg.Dir, "upgrade-state.json") }
func (m *Manager) logPath() string   { return filepath.Join(m.cfg.Dir, "upgrade.log") }
func (m *Manager) lockPath() string  { return filepath.Join(m.cfg.Dir, "upgrade.lock") }
func (m *Manager) runScript() string { return filepath.Join(m.cfg.Dir, "upgrade-run.sh") }

// ensureDir 检查 Dir 可写：先建目录再真写一个探针文件。
// 只 stat 权限位不够（root 下几乎总是"可写"，但可能撞上只读挂载/EROFS）。
func (m *Manager) ensureDir() error {
	dir := strings.TrimSpace(m.cfg.Dir)
	if dir == "" {
		return errors.New("升级管理器缺少状态目录（Dir）")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("状态目录不可用 %s: %w", dir, err)
	}
	probe := filepath.Join(dir, ".upgrade-probe")
	f, err := os.OpenFile(probe, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("状态目录不可写 %s: %w", dir, err)
	}
	_ = f.Close()
	_ = os.Remove(probe)
	return nil
}

// expandScript 把内嵌脚本展开到 $DATA/upgrade-run.sh（0700）。
// 只有内容 sha256 与二进制内嵌版本一致才复用，保证"升级器"永远跟当前二进制同版本，
// 不会出现旧脚本配新二进制导致的协议漂移（状态字段/参数名变化）。
func (m *Manager) expandScript() (string, error) {
	m.scriptMu.Lock()
	defer m.scriptMu.Unlock()

	path := m.runScript()
	want := sha256.Sum256(scriptBytes)
	if b, err := os.ReadFile(path); err == nil && sha256.Sum256(b) == want {
		if fi, err := os.Stat(path); err == nil && fi.Mode().Perm() == 0o700 {
			return path, nil
		}
		if err := os.Chmod(path, 0o700); err == nil {
			return path, nil
		}
	}

	// 临时文件 + rename：脚本要么是旧的完整版，要么是新的完整版，
	// 绝不会被执行到"写了一半"的脚本。
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, scriptBytes, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(tmp, 0o700); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	syncDir(m.cfg.Dir)
	return path, nil
}

// lock 用 flock 抢 $DATA/upgrade.lock（非阻塞），与 upgrade.sh 的 `exec 9>...` 互斥。
func (m *Manager) lock() (func(), error) {
	f, err := os.OpenFile(m.lockPath(), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, ErrBusy
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}, nil
}

// writeState 原子写状态文件（临时文件 → fsync → rename → sync 目录），
// 读侧（App 轮询 /api/upgrade/status）永远不会读到半个 JSON。
func (m *Manager) writeState(s Snapshot) error {
	dir := m.cfg.Dir
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	s.UpdatedAt = now().UTC()
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	b = append(b, '\n')

	tmp, err := os.CreateTemp(dir, ".upgrade-state-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // rename 成功后这里是 no-op

	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, m.statePath()); err != nil {
		return err
	}
	syncDir(dir)
	return nil
}

// syncDir 把目录项落盘（rename 之后掉电，元数据可能还在页缓存里）。
func syncDir(dir string) {
	d, err := os.Open(dir)
	if err != nil {
		return
	}
	_ = d.Sync()
	_ = d.Close()
}

// isTerminal 判断状态是否已终结。只有非终态才会算"进行中"（挡住新请求 / 被 Reconcile 收拾）。
func isTerminal(state string) bool {
	switch state {
	case StateIdle, StateDone, StateFailed, StateRolledBack, StateInterrupted:
		return true
	}
	return false
}

// tokenRe 限制版本号/操作 ID 的字符集。
// 这两个值最终会被拼进 systemd-run 的命令行，虽然下面还有一层 shQuote，
// 但"能进命令行"的字符集本身就该收紧（纵深防御，防注入）。
var tokenRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`)

func validToken(name, v string) error {
	if !tokenRe.MatchString(v) {
		return fmt.Errorf("%s 非法（仅允许字母数字与 . _ + -，1-64 位）: %q", name, v)
	}
	return nil
}

// shQuote 单引号转义，保证任意内容在 /bin/bash -lc 里都是纯字面量。
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "-"
	}
	return s
}

// ScriptSHA256 返回内嵌升级脚本的 sha256（十六进制），供自检/日志使用。
func ScriptSHA256() string {
	sum := sha256.Sum256(scriptBytes)
	return hex.EncodeToString(sum[:])
}
