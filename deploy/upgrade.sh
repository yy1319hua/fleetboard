#!/usr/bin/env bash
# fleetboard 面板自更新脚本（root 运行，**全程非交互**）
#
# ─────────────────────────────────────────────────────────────────────────────
# 为什么必须由独立的 systemd unit 来跑（本脚本最重要的一条约束）
# ─────────────────────────────────────────────────────────────────────────────
# fleetboard.service 是 Type=simple，`systemctl stop fleetboard` 会杀掉同一 cgroup 内的
# **所有**进程。`exec.Command` 起的子进程、setsid、nohup、disown 都只换 session/进程组，
# **不换 cgroup**，照样被连带杀死——升级进程会死在自己执行的"停服务"那一步，永远走不到换文件。
# 唯一正确做法：升级逻辑跑在独立的 transient unit 里：
#   systemd-run --unit=fleetboard-upgrade-<ts> --collect --no-block ...
# 该 unit **不继承**父 unit 的沙箱，所以脚本写的每条路径都必须由调用方用
#   -p ReadWritePaths=/opt/fleetboard -p ReadWritePaths=/var/lib/fleetboard
# 显式放行，否则写盘 EROFS（由 internal/upgrade.Manager.Start() 负责传）。
#
# ─────────────────────────────────────────────────────────────────────────────
# 用法（一般由后端调用，人工也可直接跑）
# ─────────────────────────────────────────────────────────────────────────────
#   upgrade.sh --target v0.2.3 [--from v0.2.2] [--op-id <id>]   在线下载并升级
#   upgrade.sh --src /path/to/fleetboard-v0.2.3 --target v0.2.3  离线目录升级
#   upgrade.sh v0.2.3                                            兼容旧用法：位置参数=版本
#   upgrade.sh /path/to/dir                                      兼容旧用法：离线目录
#
# 退出码：0 成功（含"已是该版本"）  1 失败（能回滚的已回滚）  2 参数错误
#         3 已有升级在跑（flock 抢占失败）  4 .env 被改动而中止
#
# 可注入项（仅用于演练/测试，生产不需要设）：
#   FLEETBOARD_SYSTEMCTL        替换 systemctl 命令（无 systemd 的环境里干跑）
#   FLEETBOARD_HEALTH_INTERVAL  健康检查间隔秒数，默认 3
#   FLEETBOARD_BASE / FLEETBOARD_DATA  覆盖部署目录（干跑指向 /tmp 假目录）

set -euo pipefail

BASE=${FLEETBOARD_BASE:-/opt/fleetboard}
DATA=${FLEETBOARD_DATA:-/var/lib/fleetboard}
REPO=${FLEETBOARD_REPO:-yy1319hua/fleetboard}
SERVICE=${FLEETBOARD_SERVICE:-fleetboard}
SYSTEMCTL=${FLEETBOARD_SYSTEMCTL:-systemctl}
HEALTH_INTERVAL=${FLEETBOARD_HEALTH_INTERVAL:-3}

ENV_FILE="$BASE/.env"
BIN="$BASE/fleetboard"
BIN_PREV="$BASE/fleetboard.prev"
WEBLINK="$BASE/web-dist"
WEBSTORE="$BASE/web-dist.d"
DB="$DATA/fleetboard.db"
LOG="$DATA/upgrade.log"
STATE="$DATA/upgrade-state.json"
LOCK="$DATA/upgrade.lock"

# 健康判据（见 health_wait）：连续 2 次成功算通过，连续 10 次失败（≈30s）判失败并回滚
HEALTH_OK_NEED=2
HEALTH_FAIL_MAX=10

TARGET=""
FROM=""
OPID=""
SRC=""
PORT=""
DRYRUN=0
TMP=""
WAS_ACTIVE=0
BIN_MOVED=0
ENV_HASH_BEFORE=""
PREV_WEB_TARGET=""
WEB_TARGET=""
STATE_STARTED_AT=""

usage() {
  cat <<'USAGE'
fleetboard 面板升级（root，非交互）
  upgrade.sh --target <ver> [--from <cur>] [--op-id <id>]   在线下载升级
  upgrade.sh --src <dir> --target <ver>                    离线目录升级
  upgrade.sh <ver> | <dir>                                 兼容旧用法
  upgrade.sh --dry-run ...                                 演练：只取包校验，不换文件
退出码：0 成功/已是该版本  1 失败(已回滚)  2 参数错误  3 已有升级在跑  4 .env 被改动
USAGE
}

# ─────────────────────────── 通用工具 ───────────────────────────

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'; }

# 目录项落盘：rename 只保证目录项已提交到内核，掉电时元数据可能还在页缓存里，
# 所以状态文件写完对父目录 sync 一次（sync -f 是 Linux 的 syncfs，比全盘 sync 便宜）。
sync_dir() { sync -f "$1" 2>/dev/null || sync 2>/dev/null || true; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sanitize_version() { printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'; }

die() { echo "❌ $1" >&2; return "${2:-1}"; }

json_field() { # 从状态文件里取一个字符串字段（状态文件始终是单行 JSON）
  [ -f "$STATE" ] || return 0
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE" | head -n 1
}

# 阶段点写状态文件。字段顺序/名字与 internal/upgrade.Snapshot 的 json tag 完全一致。
# 写法：临时文件 → chmod 600 → mv（rename 是原子的，读侧永远看不到半个 JSON）→ sync 父目录。
# state_is_current：状态文件是否属于「本次进行中」的升级请求。
#
# 为什么需要它：后端在 Start() 时先把 from/to/op_id/started_at 写进 state 再拉起本脚本，
# 目的是让 App 对账。但上一轮升级结束后 state 仍是终态记录（done/failed/...），
# 脚本过去无条件沿用它的 from——于是下次手动升级会：
#   ① 显示出错误的基线（实测把 v0.4.3 报成 v0.4.2）；
#   ② 让后面 `TARGET = FROM` 的幂等判断误判「已是该版本」直接跳过，实际什么都没换；
#   ③ 把 App 的已耗时算成上一轮的开始时间。
# 判据与后端 busyWindow（30 分钟）同口径：非终态 + started_at 未超窗。
# 超窗的 running 是机器重启/进程消失留下的残影（后端由 Reconcile 收成 interrupted）。
state_is_current() {
  [ -f "$STATE" ] || return 1
  local st sa ts now
  st=$(json_field state || true)
  case "$st" in
    ""|idle|done|failed|rolled_back|interrupted) return 1 ;;
  esac
  sa=$(json_field started_at || true)
  [ -n "$sa" ] || return 1
  ts=$(date -d "$sa" +%s 2>/dev/null || echo 0)
  now=$(date +%s)
  [ "$ts" -gt 0 ] || return 1
  [ $((now - ts)) -lt 1800 ]
}

write_state() { # $1=state $2=phase_text $3=error_code
  local st="$1" ph="$2" ec="${3:-}" tmp
  tmp="$STATE.tmp.$$"
  printf '{"state":"%s","phase_text":"%s","from":"%s","to":"%s","error_code":"%s","started_at":"%s","updated_at":"%s","log_path":"%s","op_id":"%s"}\n' \
    "$(json_escape "$st")" "$(json_escape "$ph")" "$(json_escape "$FROM")" "$(json_escape "$TARGET")" \
    "$(json_escape "$ec")" "$(json_escape "$STATE_STARTED_AT")" "$(now_utc)" \
    "$(json_escape "$LOG")" "$(json_escape "$OPID")" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE"
  sync_dir "$DATA"
}

# 阶段推进 + 落状态。状态写失败不能中断升级（日志里仍有完整记录），只告警。
say() { # $1=state $2=phase_text $3=error_code
  echo "==> [$1] $2"
  write_state "$1" "$2" "${3:-}" || echo "⚠️  状态文件写入失败（$STATE），继续执行"
}

# ─────────────────────────── 参数与前置检查 ───────────────────────────

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --target|--to)
        [ $# -ge 2 ] || die "--target 缺参数值" 2; TARGET="$2"; shift 2 ;;
      --target=*) TARGET="${1#*=}"; shift ;;
      --from)
        [ $# -ge 2 ] || die "--from 缺参数值" 2; FROM="$2"; shift 2 ;;
      --from=*) FROM="${1#*=}"; shift ;;
      --op-id)
        [ $# -ge 2 ] || die "--op-id 缺参数值" 2; OPID="$2"; shift 2 ;;
      --op-id=*) OPID="${1#*=}"; shift ;;
      --src)
        [ $# -ge 2 ] || die "--src 缺参数值" 2; SRC="$2"; shift 2 ;;
      --src=*) SRC="${1#*=}"; shift ;;
      --port)
        [ $# -ge 2 ] || die "--port 缺参数值" 2; PORT="$2"; shift 2 ;;
      --port=*) PORT="${1#*=}"; shift ;;
      # 演练开关：只落状态 + 打印，不停/起服务、不做健康检查（人工演练用）
      --dry-run) DRYRUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "未知参数：$1（--help 看用法）" 2 ;;
      *)
        # 兼容旧用法：位置参数既可能是版本号，也可能是离线发布目录
        if [ -d "$1" ]; then SRC="$1"
        elif [ -z "$TARGET" ]; then TARGET="$1"
        else die "多余参数：$1" 2; fi
        shift ;;
    esac
  done
}

need_root() {
  [ "$(id -u)" = 0 ] || die "请用 root 运行" 1
}

read_port() {
  if [ -n "$PORT" ]; then return 0; fi
  # head -n1：.env 被重复追加过 PORT 时不至于拼出 "8080\n9999" 这种脏值
  PORT=$(grep -E '^PORT=' "$ENV_FILE" 2>/dev/null | head -n 1 | cut -d= -f2 | tr -d ' ' || true)
  PORT=${PORT:-8080}
}

health_url() { printf 'http://127.0.0.1:%s/api/health' "$PORT"; }

probe_version() { # 从运行中的实例读当前版本（/api/health 的 data.version）
  local body
  body=$(curl -fsS --max-time 5 "$(health_url)" 2>/dev/null) || return 1
  printf '%s' "$body" | tr -d ' \n\r\t' | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n 1
}

# ─────────────────────────── 阶段 1：取包 + 校验（停机之前完成） ───────────────────────────

fetch_package() {
  if [ -n "$SRC" ]; then
    [ -d "$SRC" ] || die "离线发布目录不存在：$SRC" 1
    echo "==> 离线升级：使用本地发布目录 $SRC"
    return 0
  fi

  local arch tarch ver url sums
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) tarch=amd64 ;;
    aarch64|arm64) tarch=arm64 ;;
    *) die "不支持的架构: $arch（仅支持 amd64/arm64）" 1 ;;
  esac

  ver="$TARGET"
  if [ -z "$ver" ] || [ "$ver" = latest ]; then
    ver=$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" \
          | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$ver" ] || die "获取最新版本失败" 1
  fi
  TARGET="$ver"
  echo "==> fleetboard $ver ($tarch)"

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleetboard-upgrade.XXXXXX")
  url="https://github.com/$REPO/releases/download/$ver/fleetboard-$ver-linux-$tarch.tar.gz"
  echo "==> 下载 $url"
  # 必须带超时：升级进程从头到尾持有 flock，网络卡死会把整条升级链挂住
  # （App 侧一直 polling、新的升级请求全部 ErrBusy）。宁可失败退出让人重试。
  curl -fSL --progress-bar --connect-timeout 10 --max-time 900 -o "$TMP/pkg.tar.gz" "$url" \
    || die "下载失败或超时：$url" 1

  sums=$(curl -fsSL --max-time 20 "https://github.com/$REPO/releases/download/$ver/sums.txt" 2>/dev/null || true)
  if [ -n "$sums" ]; then
    printf '%s\n' "$sums" | grep "linux-$tarch.tar.gz" \
      | sed "s|fleetboard-$ver-linux-$tarch.tar.gz|$TMP/pkg.tar.gz|" | sha256sum -c - >/dev/null \
      || die "SHA256 校验不匹配，中止" 1
    echo "==> SHA256 校验通过"
  else
    echo "⚠️  未找到 sums.txt，跳过校验（仅限内网/离线场景）"
  fi

  tar xzf "$TMP/pkg.tar.gz" -C "$TMP"
  SRC="$TMP/fleetboard-$ver"
}

verify_package() {
  [ -x "$SRC/fleetboard" ] || die "发布目录缺二进制 fleetboard" 1
  [ -f "$SRC/web-dist/index.html" ] || die "发布目录缺 web-dist/" 1

  # 架构校验：直接读 ELF 头 e_machine（62=amd64, 183=arm64），不依赖 file 命令
  local host want elf
  host=$(uname -m)
  case "$host" in x86_64) want=62 ;; aarch64|arm64) want=183 ;; *) want=0 ;; esac
  elf=$(od -An -j18 -N2 -tu2 "$SRC/fleetboard" | tr -d ' ')
  [ "$elf" = "$want" ] || die "二进制架构(e_machine=$elf)与本机($host)不符" 1
  echo "==> 发布包校验通过（架构 $host / e_machine=$elf）"
}

# ─────────────────────────── 前端目录：symlink 原子切换 ───────────────────────────

# 切链接用「先建临时链接 + rename 覆盖」而不是 `ln -sfn`：
# ln -sfn 是 unlink+symlink 两步，中间有一瞬 web-dist 不存在（请求 404/白屏）；
# rename(2) 覆盖符号链接是原子的，任何瞬间 web-dist 都指向一个完整目录。
switch_webdist() { # $1 = web-dist.d 下的目录名
  local want="$1" tmp="$BASE/.web-dist.switch.$$"
  ln -sfn "web-dist.d/$want" "$tmp"
  if mv -Tf "$tmp" "$WEBLINK" 2>/dev/null; then return 0; fi
  # busybox 的 mv 没有 -T：退化成先删后建（极短窗口，仅缺 GNU coreutils 的机器）
  rm -f "$tmp"
  ln -sfn "web-dist.d/$want" "$WEBLINK"
}

# 同 backup_db：调用点在 `webdist_prepare || {...}` 里，errexit 被关掉，必须显式判错。
webdist_prepare() {
  mkdir -p "$WEBSTORE" || return 1

  # 首次运行：老布局里 web-dist 是实体目录。先整体平移进 web-dist.d/<旧版本>，
  # 再让 web-dist 变成指向它的符号链接——之后所有升级/回滚都只是换链接目标，
  # 不会再出现"旧后端 + 新前端 = 白屏"那种只还原了二进制的情况。
  if [ -d "$WEBLINK" ] && [ ! -L "$WEBLINK" ]; then
    local old
    old=$(sanitize_version "${FROM:-legacy}")
    if [ -e "$WEBSTORE/$old" ]; then old="$old-$(date +%s)"; fi
    echo "==> 首次迁移前端：web-dist → web-dist.d/$old"
    mv "$WEBLINK" "$WEBSTORE/$old" || return 1
    PREV_WEB_TARGET="$old"
    switch_webdist "$old" || return 1
  elif [ -L "$WEBLINK" ]; then
    PREV_WEB_TARGET=$(basename "$(readlink "$WEBLINK")")
    echo "==> 当前前端：web-dist → web-dist.d/$PREV_WEB_TARGET"
  fi
  return 0
}

# 同 backup_db：调用点在 `if ! webdist_install ...` 里，errexit 被关掉，必须显式判错。
webdist_install() { # $1=版本名 $2=源 web-dist 目录
  local name="$1" from="$2"
  name=$(sanitize_version "$name")
  if [ -d "$WEBSTORE/$name" ] && [ -f "$WEBSTORE/$name/index.html" ]; then
    # 同版本目录内容由版本决定、不可变，直接复用：既省 IO，也不会误删回滚目标
    echo "==> 复用已有前端 web-dist.d/$name"
  else
    echo "==> 安装前端 → web-dist.d/$name"
    rm -rf "${WEBSTORE:?}/$name" || return 1
    mkdir -p "$WEBSTORE/$name" || return 1
    # -a 保留权限/时间；末尾 /. 保证拷的是内容而不是目录本身
    cp -a "$from/." "$WEBSTORE/$name/" || return 1
  fi
  WEB_TARGET="$name"
  switch_webdist "$name" || return 1
  echo "==> 已切换 web-dist → web-dist.d/$name"
  return 0
}

webdist_prune() { # 保留：当前 + 回滚目标 + 最近一代（共 3 代，2026-10-29 用户指定）
  local keep_cur="$1" keep_prev="${2:-}" d name n=0
  for d in $(ls -1dt "$WEBSTORE"/*/ 2>/dev/null || true); do
    name=$(basename "$d")
    [ "$name" = "$keep_cur" ] && continue
    if [ -n "$keep_prev" ] && [ "$name" = "$keep_prev" ]; then continue; fi
    n=$((n + 1))
    if [ "$n" -gt 1 ]; then
      echo "   清理旧前端：web-dist.d/$name"
      rm -rf "${WEBSTORE:?}/$name"
    fi
  done
}

# ─────────────────────────── 数据库备份 ───────────────────────────

# 注意：本函数的调用点是 `backup_db || {...}`，属于"条件上下文"，bash 会关掉这里的 errexit。
# 所以每一步都必须显式判错并 return 1，不能指望 set -e 兜底。
backup_db() {
  [ -f "$DB" ] || { echo "==> 未发现数据库文件，跳过备份"; return 0; }
  mkdir -p "$DATA/backup" || return 1
  local bf
  bf="$DATA/backup/fleetboard-$(date +%F-%H%M%S).db"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "VACUUM INTO '$bf'" || return 1
    echo "==> 数据库快照（VACUUM INTO）→ $bf"
  else
    # 部署机上没有 sqlite3（后端用 modernc 纯 Go 驱动，不需要 CGO）。
    # 所以只能文件级拷贝；WAL 模式下未 checkpoint 的事务还在 -wal 里，
    # 必须连 -wal/-shm 一起拷，否则快照会丢掉最近一次写入。
    cp -p "$DB" "$bf" || return 1
    if [ -f "$DB-wal" ]; then cp -p "$DB-wal" "$bf-wal" || return 1; fi
    if [ -f "$DB-shm" ]; then cp -p "$DB-shm" "$bf-shm" || return 1; fi
    echo "==> 数据库快照（含 WAL/SHM）→ $bf"
  fi
  # 只留最近 3 份（含 WAL/SHM 附加文件一起清）
  local old
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    rm -f "$old" "$old-wal" "$old-shm"
  done <<EOF
$(ls -1t "$DATA/backup"/fleetboard-*.db 2>/dev/null | tail -n +4 || true)
EOF
  return 0
}

# ─────────────────────────── 健康检查 ───────────────────────────

# 判据：HTTP 200（curl -f 保证）且 data.status == "ok"，且 data.version == 目标 tag。
# 只看 200 不够——刚启动的旧进程也会 200，必须用 version 证明"新二进制真的起来了"。
health_once() {
  local body compact
  body=$(curl -fsS --max-time 5 "$(health_url)" 2>/dev/null) || return 1
  compact=$(printf '%s' "$body" | tr -d ' \n\r\t')
  case "$compact" in *'"status":"ok"'*) ;; *) return 1 ;; esac
  if [ -n "$TARGET" ]; then
    case "$compact" in *"\"version\":\"$TARGET\""*) ;; *) return 1 ;; esac
  fi
  return 0
}

health_wait() {
  local ok=0 fail=0
  while :; do
    if health_once; then
      ok=$((ok + 1)); fail=0
      if [ "$ok" -ge "$HEALTH_OK_NEED" ]; then
        echo "==> 健康检查通过（连续 $ok 次）"
        return 0
      fi
    else
      fail=$((fail + 1)); ok=0
      if [ "$fail" -ge "$HEALTH_FAIL_MAX" ]; then
        echo "❌ 连续 $fail 次健康检查失败（间隔 ${HEALTH_INTERVAL}s）" >&2
        return 1
      fi
    fi
    sleep "$HEALTH_INTERVAL"
  done
}

# ─────────────────────────── 回滚 ───────────────────────────

rollback() { # $1=原因 $2=error_code
  local reason="$1" code="${2:-upgrade_failed}"
  echo "❌ 升级失败：$reason，开始回滚" >&2
  write_state rolled_back "升级失败（$reason），正在回滚" "$code" || true

  "$SYSTEMCTL" stop "$SERVICE" >/dev/null 2>&1 || true

  # 二进制：只有"本次确实把旧二进制改名了"才还原。
  # 不加这个判断会出事：备份阶段就失败时，$BIN_PREV 可能是上一次升级留下的旧文件，
  # 直接改名回去等于悄悄把面板降级了一个版本。
  if [ "${BIN_MOVED:-0}" = 1 ] && [ -f "$BIN_PREV" ]; then
    if mv -f "$BIN_PREV" "$BIN"; then
      echo "   已恢复旧二进制 $BIN" >&2
    else
      echo "⚠️  还原旧二进制失败：请手工 mv $BIN_PREV $BIN" >&2
    fi
  fi

  # 前端：把符号链接切回旧代号——这是本次改造的核心，只回滚二进制会留下"旧后端+新前端"（白屏）。
  # 用"当前链接是否已指向旧代号"来判断而不是加开关，天然幂等：没换过前端就不会乱切。
  if [ -n "$PREV_WEB_TARGET" ] && [ -d "$WEBSTORE/$PREV_WEB_TARGET" ]; then
    local cur=""
    if [ -L "$WEBLINK" ]; then cur=$(basename "$(readlink "$WEBLINK")"); fi
    if [ "$cur" != "$PREV_WEB_TARGET" ]; then
      switch_webdist "$PREV_WEB_TARGET"
      echo "   已切回旧前端 web-dist.d/$PREV_WEB_TARGET" >&2
    fi
  fi

  if [ "$WAS_ACTIVE" = 1 ]; then
    "$SYSTEMCTL" start "$SERVICE" >/dev/null 2>&1 || true
    # 回滚后只确认"进程起来了"，不再校验版本：旧版本此刻不健康也可能是机器环境问题，
    # 把判断权留给人（日志与下方命令已给出排查入口）。
    local i
    for i in $(seq 1 10); do
      if "$SYSTEMCTL" is-active --quiet "$SERVICE" 2>/dev/null; then
        echo "   服务已用旧版本重新启动" >&2
        break
      fi
      sleep 1
    done
  fi
  echo "   排查：journalctl -u $SERVICE -n 100；完整日志：$LOG" >&2
  say failed "升级失败已回滚：$reason" "$code"
  return 1
}

# ─────────────────────────── 主流程 ───────────────────────────

cleanup() {
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
}

main() {
  parse_args "$@"
  need_root
  [ -f "$ENV_FILE" ] || die "未检测到已安装（缺 $ENV_FILE），请先用 install.sh 安装" 1
  [ -x "$BIN" ] || die "缺 $BIN，无法升级" 1

  mkdir -p "$DATA"
  trap cleanup EXIT

  # 单实例：flock 拿不到就直接退 3。用 fd 9 持有到进程结束，
  # 后端 Start() 也用同一把锁（$DATA/upgrade.lock），两边互斥。
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock -n 9 || die "已有升级在进行（$LOCK 被占用），本次不执行" 3
  else
    echo "⚠️  没有 flock，跳过单实例保护"
  fi

  # 只在「本次进行中」的情况下沿用后端写入的 started_at / op_id / from（见 state_is_current）
  if state_is_current; then
    STATE_STARTED_AT=$(json_field started_at || true)
    if [ -z "$OPID" ]; then OPID=$(json_field op_id || true); fi
    if [ -z "$FROM" ]; then FROM=$(json_field from || true); fi
  fi
  if [ -z "$STATE_STARTED_AT" ]; then STATE_STARTED_AT=$(now_utc); fi
  if [ -z "$OPID" ]; then OPID="manual-$(date +%s)"; fi
  read_port

  # ── 阶段 0：看当前版本（幂等判断要用，必须在停服前做）──
  # 以运行实例自报的版本（/api/health 的 data.version）为准：它反映的是真正在跑的二进制，
  # 比 state 记录可靠。探测失败（服务已停 / 端口不通）才退回上面从本次 state 取的 from。
  probed=$(probe_version || true)
  if [ -n "$probed" ]; then FROM="$probed"; fi
  # 目标版本与当前版本一致 → 什么都不换，只把状态收成终态（否则 App 会一直等到 busy 窗口超时）
  if [ -n "$TARGET" ] && [ "$TARGET" != latest ] && [ "$TARGET" = "$FROM" ]; then
    say done "已是该版本（$TARGET），无需升级"
    echo "    未改动任何部署文件（二进制 / web-dist / .env / 数据库）"
    return 0
  fi
  say verifying "准备升级：${FROM:-未知} → ${TARGET:-最新}"

  # ── 阶段 1：取包、校验（网络与解包全部在停服之前）──
  fetch_package
  verify_package

  if [ "$DRYRUN" = 1 ]; then
    say done "演练结束（--dry-run）：未停服、未替换任何文件"
    return 0
  fi

  # ── 阶段 2：进入停机窗口，只做本地文件操作 ──
  ENV_HASH_BEFORE=$(sha256sum "$ENV_FILE" | cut -d' ' -f1)
  if "$SYSTEMCTL" is-active --quiet "$SERVICE" 2>/dev/null; then WAS_ACTIVE=1; fi

  say stopping "停止服务 $SERVICE"
  if [ "$WAS_ACTIVE" = 1 ]; then
    "$SYSTEMCTL" stop "$SERVICE" || true
    local i
    for i in $(seq 1 15); do
      if ! "$SYSTEMCTL" is-active --quiet "$SERVICE" 2>/dev/null; then break; fi
      sleep 1
    done
  else
    echo "    服务当前未运行，跳过 stop"
  fi

  say backing_up "备份数据库"
  backup_db || { rollback "数据库备份失败" db_backup_failed; return 1; }

  say replacing "替换二进制与前端"
  webdist_prepare || { rollback "前端目录迁移失败" replace_failed; return 1; }

  # 二进制换 inode：先把新文件落到 BASE 内的临时名（同一文件系统，rename 才原子），
  # 再把运行中的旧文件改名留档，最后 rename 覆盖——绝不 `cp` 覆盖正在执行的二进制
  # （cp 是就地截断写，内核会报 ETXTBSY / 写出半个 ELF）。
  # 每一步失败都单独回滚：服务此刻是停着的，不回滚就是"面板躺在停机状态"。
  if ! install -m 755 "$SRC/fleetboard" "$BASE/.fleetboard.new.$$"; then
    rm -f "$BASE/.fleetboard.new.$$"
    rollback "写入新二进制失败（磁盘满或权限？）" replace_failed
    return 1
  fi
  if ! mv -f "$BIN" "$BIN_PREV"; then
    rollback "旧二进制改名留档失败" replace_failed
    return 1
  fi
  BIN_MOVED=1 # 从这一刻起旧二进制只剩 $BIN_PREV 一份，回滚必须还原
  if ! mv -f "$BASE/.fleetboard.new.$$" "$BIN"; then
    rollback "新二进制就位失败" replace_failed
    return 1
  fi
  echo "   新二进制已就位，旧版留作 $BIN_PREV"

  # 离线目录且没给 --target 时用时间戳命名，避免覆盖上一代目录
  local newdist
  newdist="${TARGET:-local-$(date +%s)}"
  if ! webdist_install "$newdist" "$SRC/web-dist"; then
    rollback "替换前端失败" replace_failed
    return 1
  fi
  if [ -f "$SRC/uninstall.sh" ]; then install -m 755 "$SRC/uninstall.sh" "$BASE/uninstall.sh"; fi

  # ── 阶段 3：起服务 + 健康判据 ──
  # 无论升级前是否在跑都要 start：面板是 App 的唯一入口，升级完不拉起来就等于失联。
  say starting "启动服务 $SERVICE"
  "$SYSTEMCTL" start "$SERVICE" || { rollback "systemctl start 失败" start_failed; return 1; }

  say health_check "健康检查（目标版本 ${TARGET:-未指定}）"
  if ! health_wait; then
    rollback "健康检查未通过（连续 ${HEALTH_FAIL_MAX} 次）" health_check_failed
    return 1
  fi

  # ── 阶段 4：收尾校验 ──
  # .env 必须一字未动：install.sh 重跑会重新生成 KEY，已存凭据将永久无法解密。
  # 本脚本全程不写 .env，一旦 sha256 变了说明有外部力量动过它 → 中止并报 env_changed。
  if [ "$(sha256sum "$ENV_FILE" | cut -d' ' -f1)" != "$ENV_HASH_BEFORE" ]; then
    say failed "升级中止：$ENV_FILE 在升级期间被外部改动（sha256 不一致），请人工核查" env_changed
    return 4
  fi

  webdist_prune "${WEB_TARGET:-$PREV_WEB_TARGET}" "$PREV_WEB_TARGET"

  say done "升级完成：${FROM:-未知} → ${TARGET:-未知}"
  echo "    旧二进制：$BIN_PREV"
  echo "    旧前端  ：web-dist.d/${PREV_WEB_TARGET:-<无>}（回滚即切回该目录：ln -sfn web-dist.d/${PREV_WEB_TARGET:-<旧版本>} $WEBLINK）"
  echo "    数据库快照：$DATA/backup/（保留最近 3 份）"
  echo "    .env sha256 前后一致，数据库未改动；完整日志：$LOG"
  return 0
}

# ── 全程 tee ──
# 这里**不用** `main "$@" | tee -a "$LOG"; exit ${PIPESTATUS[0]}`：
# 一旦 main 位于管道（或 `|| rc=$?` 列表里），bash 会关掉那个子 shell 的 errexit，
# `set -e` 静默失效 —— 升级脚本会变成"出错继续跑"，比丢日志危险得多；
# 而且 `pipestatus` 在 `|| rc=$?` 之后已经被覆盖，取到的是 0。
# 改用进程替换：主流程留在当前 shell（errexit 正常），退出码就是主流程的退出码。
# 日志自轮转：>5MB 时把旧日志挪成 .1（只留一代，更早的直接丢弃），避免日志吃满磁盘。
mkdir -p "$DATA" 2>/dev/null || true
if [ -d "$DATA" ] && [ -w "$DATA" ]; then
  if [ -f "$LOG" ]; then
    LOG_SIZE=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt $((5 * 1024 * 1024)) ]; then
      mv -f "$LOG" "$LOG.1"
    fi
  fi
  exec > >(tee -a "$LOG") 2>&1
fi

main "$@"
exit $?
