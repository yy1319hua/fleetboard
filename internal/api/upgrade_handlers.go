package api

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/yy1319hua/fleetboard/internal/auth"
	"github.com/yy1319hua/fleetboard/internal/db"
	"github.com/yy1319hua/fleetboard/internal/model"
	"github.com/yy1319hua/fleetboard/internal/upgrade"
)

// 面板自更新的环境变量名与默认路径。
// 取值对齐部署侧既有约定（deploy/install.sh、internal/upgrade 的内嵌脚本、config 包），
// 一处改名会让「脚本能跑但开关读不到」，因此 api 与 cmd 共用这份事实源。
const (
	EnvSelfUpgrade     = "FLEETBOARD_UPGRADE_ENABLED" // 开关，默认 false（危险操作，默认不开放）
	EnvUpgradeBaseDir  = "FLEETBOARD_BASE"            // 安装根目录，内含 .env 与二进制
	EnvUpgradeStateDir = "FLEETBOARD_DATA"            // 状态与日志目录（默认同 DATA_DIR）

	DefaultUpgradeBaseDir  = "/opt/fleetboard"
	DefaultUpgradeStateDir = "/var/lib/fleetboard"

	// 日志尾行数：够看清卡在哪一步，又不至于把 App 首屏撑爆。
	upgradeLogTailLines = 20
	// 目标版本允许的字符集：与编排层的校验一致（纵深防御，给出更准确的 400 而非 409）。
	upgradeVersionPattern = `^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`
	// 升级查询整体超时（外呼自带 5s 上限，这里留一点解析余量）。
	upgradeInfoTimeout = 6 * time.Second
)

// UpgradeManager 是自更新编排层（internal/upgrade.Manager）在本包里的最小依赖面。
// 抽成接口只为可测：生产恒为 *upgrade.Manager，测试注入假实现观察 202/409 等分支。
type UpgradeManager interface {
	Snapshot() upgrade.Snapshot
	LogTail(n int) []string
	Start(targetVersion, opID string) error
	Enabled() bool
	Reconcile() (upgrade.Snapshot, bool)
}

// UpgradeWiring 是 main 装配好的自更新依赖（nil 时本包按环境变量自建）。
type UpgradeWiring struct {
	Manager UpgradeManager
	Enabled bool   // 配置开关 SELF_UPGRADE
	BaseDir string // 安装根目录（用于检查 .env）

	// EnvCheck 可选：覆盖「运行环境是否满足」的判断，返回不满足的中文原因（空串=满足）。
	// 生产留空走真实检查；测试注入以覆盖 202 分支（容器里没有 /opt/fleetboard）。
	EnvCheck func() string

	// Source 可选：覆盖最新版本来源（生产留空走 GitHub Releases）。测试注入用。
	Source versionSource
}

// upgradeService 收敛自更新的有状态部件。
// 每个 RouterOptions 一份而非包级单例：多实例并存时缓存与退避计数不会互相污染。
type upgradeService struct {
	mgr      UpgradeManager
	enabled  bool
	baseDir  string
	cur      string
	src      versionSource
	guard    *passwordGuard
	envCheck func() string
}

// newUpgradeService 组装自更新服务；wiring 为 nil 时按环境变量自建（测试/最小启动路径）。
func newUpgradeService(version string, w *UpgradeWiring) *upgradeService {
	if w == nil {
		w = upgradeWiringFromEnv(version)
	}
	baseDir := strings.TrimSpace(w.BaseDir)
	if baseDir == "" {
		baseDir = DefaultUpgradeBaseDir
	}
	svc := &upgradeService{
		mgr:     w.Manager,
		enabled: w.Enabled,
		baseDir: baseDir,
		cur:     version,
		src:     w.Source,
		guard:   newPasswordGuard(),
	}
	if svc.src == nil {
		svc.src = newGitHubVersionSource()
	}
	svc.envCheck = w.EnvCheck
	if svc.envCheck == nil {
		svc.envCheck = func() string { return upgradeEnvReason(baseDir) }
	}
	return svc
}

// upgradeWiringFromEnv 按环境变量装配（未注入 wiring 时的兜底）。
func upgradeWiringFromEnv(version string) *UpgradeWiring {
	baseDir := envOr(EnvUpgradeBaseDir, DefaultUpgradeBaseDir)
	stateDir := envOr(EnvUpgradeStateDir, DefaultUpgradeStateDir)
	enabled := envBool(EnvSelfUpgrade)
	return &UpgradeWiring{
		Enabled: enabled,
		BaseDir: baseDir,
		Manager: upgrade.NewManager(upgrade.Config{
			Dir:     stateDir,
			BaseDir: baseDir,
			Version: version,
			// Enabled 表达「环境是否满足」；开关与环境的合取在 handler 里再判一次，
			// 因为两者要给出不同的中文原因（未开启 vs 环境不满足）。
			Enabled: enabled && upgradeEnvReason(baseDir) == "",
		}),
	}
}

// envOr 读环境变量，空值回落到默认。
func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

// envBool 解析布尔型环境变量（1/true/yes/on 为真，其余一律假）。
func envBool(key string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// UpgradeEnvReady 报告运行环境是否满足自更新（供 main 组装升级管理器时判定 Enabled）。
func UpgradeEnvReady(baseDir string) bool {
	if strings.TrimSpace(baseDir) == "" {
		baseDir = DefaultUpgradeBaseDir
	}
	return upgradeEnvReason(baseDir) == ""
}

// upgradeEnvReason 判断运行环境是否具备自更新条件，返回不满足的中文原因。
//
// 两道门槛：/opt/fleetboard/.env 是 systemd 服务的配置来源（升级后新进程要能读到同一份配置），
// systemctl 用于把替换动作交给独立进程（不能被自身重启打断）。缺任一都说明这台机器不是
// install.sh 的标准布局，此时强行自更新只会把面板弄坏，所以拒绝并说清原因。
func upgradeEnvReason(baseDir string) string {
	envFile := filepath.Join(baseDir, ".env")
	if _, err := os.Stat(envFile); err != nil {
		return fmt.Sprintf("运行环境不满足：未找到 %s（请用 install.sh 标准安装）", envFile)
	}
	// 升级动作要被 systemd-run 拉进独立 unit（脱离自身 cgroup），否则停服会把自己一起杀掉。
	if _, err := exec.LookPath("systemd-run"); err != nil {
		return "运行环境不满足：未找到 systemd-run，面板未在 systemd 环境下运行"
	}
	return ""
}

// upgradeTargetRe 复用于目标版本格式校验。
var upgradeTargetRe = regexp.MustCompile(upgradeVersionPattern)

// available 表示「功能是否对外存在」：开关关或管理器缺失都视为不存在（对外 404）。
func (s *upgradeService) available() bool { return s != nil && s.enabled && s.mgr != nil }

// upgradeBusyWindow 与编排层的 busyWindow 保持一致（30 分钟）：
// 超过窗口仍未写终态的非终态视为历史残留，否则一次异常重启会把人永久锁在「升级中」。
const upgradeBusyWindow = 30 * time.Minute

// inProgress 判断是否有在途升级。状态文件是唯一事实源（跨进程存活）；
// 时间戳缺失/不可辨识时保守地按「忙」处理，避免并发触发把二进制替换成半成品。
func (s *upgradeService) inProgress() bool {
	if s == nil || s.mgr == nil {
		return false
	}
	snap := s.mgr.Snapshot()
	switch snap.State {
	case "", "idle", "done", "failed", "rolled_back", "interrupted":
		return false
	}
	if snap.StartedAt.IsZero() {
		return true
	}
	return time.Since(snap.StartedAt) < upgradeBusyWindow
}

// upgradeInfo 是 GET /api/system/upgrade 的 data。
type upgradeInfo struct {
	CurrentVersion string               `json:"current_version"`
	LatestVersion  string               `json:"latest_version"`
	UpgradeEnabled bool                 `json:"upgrade_enabled"`
	CanUpgrade     bool                 `json:"can_upgrade"`
	Reason         string               `json:"reason"`
	Last           *model.UpgradeRecord `json:"last"`
}

// upgradeStatusInfo 是 GET /api/system/upgrade/status 与 POST 202 的 data。
type upgradeStatusInfo struct {
	State     string   `json:"state"`
	PhaseText string   `json:"phase_text"`
	From      string   `json:"from"`
	To        string   `json:"to"`
	ErrorCode string   `json:"error_code"`
	LogTail   []string `json:"log_tail"`
}

// systemUpgradeInfoHandler 返回版本与可升级性。
// GET /api/system/upgrade
//
// 开关关闭时依然 200（App 需要展示「为什么不能升」），只有 POST/status 才 404。
func systemUpgradeInfoHandler(svc *upgradeService, d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		cur := strings.TrimSpace(svc.cur)
		info := upgradeInfo{
			CurrentVersion: cur,
			LatestVersion:  cur,
			UpgradeEnabled: svc.enabled,
			Last:           latestUpgradeRecord(d),
		}
		if !svc.available() {
			info.Reason = "本实例未开启面板自更新"
			OK(c, info)
			return
		}
		if !hasVersionNumber(cur) {
			// dev / 未知构建：没有可比对的版本号，别谎报「有新版」
			info.Reason = "当前版本未知（构建时未注入版本号），无法判断可升级性"
			OK(c, info)
			return
		}

		// GitHub 不可达不是错误：降级成「无法获取最新版本 + 不可升级」，绝不 500。
		ctx, cancel := context.WithTimeout(c.Request.Context(), upgradeInfoTimeout)
		defer cancel()
		latest, err := svc.src.Latest(ctx)
		if err != nil || strings.TrimSpace(latest) == "" {
			if err != nil {
				log.Printf("查询最新版本失败（已降级）: %v", err)
			}
			info.Reason = "无法获取最新版本"
			OK(c, info)
			return
		}
		info.LatestVersion = strings.TrimSpace(latest)

		// 服务端已判定的门槛逐条给出中文原因，App 直接展示，不做二次推断。
		envReason := svc.envCheck()
		switch {
		case envReason != "":
			info.Reason = envReason
		case compareVersions(info.LatestVersion, cur) <= 0:
			info.Reason = "当前已是最新版本"
		case svc.inProgress():
			info.Reason = "已有升级任务在进行"
		default:
			info.CanUpgrade = true
		}
		OK(c, info)
	}
}

// triggerUpgradeHandler 触发面板自更新。
// POST /api/system/upgrade
func triggerUpgradeHandler(svc *upgradeService, d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		// 开关关闭 → 404 而非 403：不向调用方泄露「本实例存在自更新能力」。
		if !svc.available() {
			Fail(c, ErrNotFound("接口不存在"))
			return
		}

		opID := strings.TrimSpace(c.GetHeader("X-Client-Op-Id"))
		if opID == "" {
			Fail(c, ErrBadRequest("缺少 X-Client-Op-Id 请求头（用于幂等与审计关联）"))
			return
		}

		var req struct {
			Password      string `json:"password"`
			TargetVersion string `json:"target_version"`
		}
		if err := c.ShouldBindJSON(&req); err != nil {
			Fail(c, ErrBadRequest(`请求体需为 {"password":"...","target_version":"v0.4.1"}`))
			return
		}
		if strings.TrimSpace(req.Password) == "" {
			Fail(c, ErrBadRequest("缺少登录密码（危险操作需二次确认）"))
			return
		}

		uid := CurrentUserID(c)
		// 退避优先于查库：爆破期间不该再付出 bcrypt 与 DB 的成本。
		if wait := svc.guard.blockedFor(uid); wait > 0 {
			Fail(c, ErrUnauthorized(fmt.Sprintf("密码错误次数过多，请 %d 秒后再试", wait)))
			return
		}
		usr, err := db.GetUserByID(d, uid)
		if err != nil {
			Fail(c, ErrUnauthorized("当前用户不可用，请重新登录"))
			return
		}
		if !auth.VerifyPassword(usr.PasswordHash, req.Password) {
			svc.guard.fail(uid)
			Fail(c, ErrUnauthorized("密码错误"))
			return
		}
		svc.guard.reset(uid)

		if reason := svc.envCheck(); reason != "" {
			Fail(c, ErrConflict(reason))
			return
		}
		if svc.inProgress() {
			Fail(c, ErrConflict("已有升级任务在进行"))
			return
		}

		cur := strings.TrimSpace(svc.cur)
		target := strings.TrimSpace(req.TargetVersion)
		if target == "" {
			ctx, cancel := context.WithTimeout(c.Request.Context(), upgradeInfoTimeout)
			defer cancel()
			latest, err := svc.src.Latest(ctx)
			if err != nil || strings.TrimSpace(latest) == "" {
				Fail(c, ErrConflict("无法获取最新版本，请显式指定 target_version"))
				return
			}
			target = strings.TrimSpace(latest)
		}
		if !upgradeTargetRe.MatchString(target) {
			Fail(c, ErrBadRequest(fmt.Sprintf("目标版本格式非法: %q", target)))
			return
		}
		if compareVersions(target, cur) <= 0 {
			Fail(c, ErrConflict(fmt.Sprintf("目标版本 %s 不高于当前版本 %s", target, cur)))
			return
		}

		// 先落库再触发：即便编排层随后失败，也留下了「谁在何时点了升级」。
		recID, err := db.InsertUpgradeStart(d, cur, target, uid, "")
		if err != nil {
			Fail(c, err)
			return
		}

		if err := svc.mgr.Start(target, opID); err != nil {
			// 编排层可能已自行判定终态（如 systemd-run 失败时写 failed+error_code）：
			// 优先采信它的结论，DB 只是历史镜像。
			status, code := db.UpgradeFailed, upgradeErrorCode(err)
			if snap := svc.mgr.Snapshot(); isTerminalUpgradeState(snap.State) {
				status = snap.State
				if snap.ErrorCode != "" {
					code = snap.ErrorCode
				}
				if snap.LogPath != "" {
					_ = db.SetUpgradeLogPath(d, recID, snap.LogPath)
				}
			}
			_ = db.FinishUpgrade(d, recID, status, code, 0)
			// 失败也要留审计：危险操作「被尝试过」同样需要可追溯
			writeUpgradeAudit(d, uid, cur, target, opID, "fail", code)
			switch {
			case errors.Is(err, upgrade.ErrBusy):
				Fail(c, ErrConflict("已有升级任务在进行"))
			case errors.Is(err, upgrade.ErrDisabled):
				// 环境其实不支持：与「未开启」同样处理，不额外泄露信息
				Fail(c, ErrNotFound("接口不存在"))
			default:
				log.Printf("面板自更新启动失败: %v", err)
				Fail(c, ErrConflict("升级任务启动失败，请查看升级日志"))
			}
			return
		}

		snap := svc.mgr.Snapshot()
		if snap.LogPath != "" {
			// 日志路径由编排层在 Start 时生成，落库那一刻还拿不到，故分两步写
			_ = db.SetUpgradeLogPath(d, recID, snap.LogPath)
		}

		writeUpgradeAudit(d, uid, cur, target, opID, "ok", "")

		c.Header("Location", "/api/system/upgrade/status")
		c.JSON(http.StatusAccepted, Response{
			Code: CodeOK,
			Msg:  "ok",
			Data: buildStatusInfo(svc, snap, cur, target),
		})
	}
}

// systemUpgradeStatusHandler 返回升级阶段与日志尾。
// GET /api/system/upgrade/status
func systemUpgradeStatusHandler(svc *upgradeService, d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !svc.available() {
			Fail(c, ErrNotFound("接口不存在"))
			return
		}
		snap := svc.mgr.Snapshot()
		// 轮询顺带补写终态：升级会让进程重启，「升级中」的那个自己没法写完历史表。
		syncTerminalUpgrade(d, snap)

		cur := strings.TrimSpace(svc.cur)
		from, to := snap.From, snap.To
		if st := strings.TrimSpace(snap.State); st == "" || st == "idle" {
			// 空闲时用最近一条历史补 from/to，App 首屏才有内容可显示
			if last := latestUpgradeRecord(d); last != nil {
				from, to = last.FromVersion, last.ToVersion
			}
		}
		if from == "" {
			from = cur
		}
		OK(c, buildStatusInfo(svc, snap, from, to))
	}
}

// buildStatusInfo 把编排层快照转成对外的 status 载荷。
func buildStatusInfo(svc *upgradeService, snap upgrade.Snapshot, from, to string) upgradeStatusInfo {
	tail := svc.mgr.LogTail(upgradeLogTailLines)
	if tail == nil {
		tail = []string{} // 序列化成 []，避免 App 侧判空出错
	}
	state := strings.TrimSpace(snap.State)
	if state == "" {
		state = "idle"
	}
	phase := strings.TrimSpace(snap.PhaseText)
	if phase == "" && state == "idle" {
		phase = "当前没有升级任务"
	}
	return upgradeStatusInfo{
		State:     state,
		PhaseText: phase,
		From:      from,
		To:        to,
		ErrorCode: snap.ErrorCode,
		LogTail:   tail,
	}
}

// isTerminalUpgradeState 判断状态是否终态（与 db 的 status 取值一一对应）。
func isTerminalUpgradeState(state string) bool {
	switch strings.TrimSpace(state) {
	case db.UpgradeDone, db.UpgradeFailed, db.UpgradeRolledBack, db.UpgradeInterrupt:
		return true
	}
	return false
}

// syncTerminalUpgrade 在轮询/启动对账时把终态补写进历史表。
func syncTerminalUpgrade(d *sql.DB, snap upgrade.Snapshot) {
	if d == nil || !isTerminalUpgradeState(snap.State) {
		return
	}
	rec, err := db.LatestInProgressUpgrade(d)
	if err != nil {
		log.Printf("查询在途升级记录失败: %v", err)
		return
	}
	if rec == nil {
		return
	}
	var duration int64
	if !snap.StartedAt.IsZero() && !snap.UpdatedAt.IsZero() {
		if duration = snap.UpdatedAt.Sub(snap.StartedAt).Milliseconds(); duration < 0 {
			duration = 0
		}
	}
	if err := db.FinishUpgrade(d, rec.ID, snap.State, snap.ErrorCode, duration); err != nil {
		log.Printf("补写升级终态失败: %v", err)
	}
}

// latestUpgradeRecord 返回最近一条升级记录；无记录或查询失败时返回 nil。
func latestUpgradeRecord(d *sql.DB) *model.UpgradeRecord {
	if d == nil {
		return nil
	}
	rows, err := db.LatestUpgrades(d, 1)
	if err != nil {
		log.Printf("查询升级历史失败: %v", err)
		return nil
	}
	if len(rows) == 0 {
		return nil
	}
	return &rows[0]
}

// writeUpgradeAudit 写专用审计。
// AuditMiddleware 的通用记录只留 URL，还原不出 from/to/opId，事后无法追责到具体操作。
func writeUpgradeAudit(d *sql.DB, uid int64, from, to, opID, result, errorCode string) {
	detail := fmt.Sprintf("from=%s to=%s opId=%s", from, to, opID)
	if errorCode != "" {
		detail += " error=" + errorCode
	}
	if err := db.InsertAudit(d, uid, nil, "system.upgrade.request", detail, result); err != nil {
		log.Printf("写升级审计失败: %v", err)
	}
}

// upgradeErrorCode 把编排层错误收敛成稳定的错误码，供历史表与 App 展示。
func upgradeErrorCode(err error) string {
	switch {
	case errors.Is(err, upgrade.ErrBusy):
		return "busy"
	case errors.Is(err, upgrade.ErrDisabled):
		return "disabled"
	default:
		return "start_failed"
	}
}

// upgradeHistoryHandler 返回升级历史分页。
// GET /api/system/upgrades?limit=20&offset=0
//
// 与 GET /system/upgrade 的分工：前者只回最近一条（首屏用），本端点回全量分页
// （升级历史页用）。合成一个端点会让首屏被迫拉回全表，而历史页又拿不到分页。
//
// 开关关闭时同样 404：不泄露「这台面板具备自更新能力」这件事。
func upgradeHistoryHandler(svc *upgradeService, d *sql.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !svc.available() {
			Fail(c, ErrNotFound("接口不存在"))
			return
		}

		limit, offset := 20, 0
		if v := strings.TrimSpace(c.Query("limit")); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n <= 0 {
				Fail(c, ErrBadRequest("limit 必须是正整数"))
				return
			}
			limit = n
		}
		if v := strings.TrimSpace(c.Query("offset")); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 0 {
				Fail(c, ErrBadRequest("offset 必须是非负整数"))
				return
			}
			offset = n
		}

		items, total, err := db.ListUpgrades(d, limit, offset)
		if err != nil {
			Fail(c, err)
			return
		}
		if items == nil {
			// 序列化成 []：App 侧对 null 判空与对 [] 判空的代码路径不同，
			// 统一给 [] 可以少一条分支，也少一类线上空指针。
			items = []model.UpgradeRecord{}
		}
		OK(c, gin.H{
			"items":  items,
			"total":  total,
			"limit":  limit,
			"offset": offset,
		})
	}
}
