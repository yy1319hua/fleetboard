import '../../updater/domain/sem_ver.dart';

/// App 内置的「支持面板自更新的最低面板版本」。
///
/// 为什么这个常量在**客户端**而不是只放在服务端：低于该版本的面板没有
/// `/api/system/upgrade*` 这套端点（也没有 systemd-run 那套脱离 cgroup 的执行方式），
/// 请求只会拿到 404。等用户点了按钮再失败，他会以为「升级坏了」；
/// 客户端事先知道门槛，就能把「你该手工升一次」这句话提前说清楚。
const String minSelfUpgradeVersion = '0.4.0';

/// 手动升级命令：低于最低版本、以及升级失联时，给的都是同一条可复制命令。
const String manualUpgradeCommand = 'sudo /opt/fleetboard/upgrade.sh';

/// 服务端认的开关键名（写进 `/opt/fleetboard/.env`）。
const String upgradeEnabledEnvKey = 'FLEETBOARD_UPGRADE_ENABLED';

/// `GET /api/system/upgrade` 的载荷。
class PanelUpgradeInfo {
  const PanelUpgradeInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.upgradeEnabled,
    required this.canUpgrade,
    required this.reason,
    this.last,
  });

  final String currentVersion;
  final String latestVersion;

  /// 服务端是否开启了自更新（`upgrade_enabled=false` 时整页只读）。
  final bool upgradeEnabled;

  /// 当前是否真的可升级（服务端已综合「已是最新 / 有任务在跑 / 环境不满足」）。
  final bool canUpgrade;

  /// 不可升级的中文原因（服务端给，客户端不二次推断）。
  final String reason;

  /// 最近一次升级记录。
  final UpgradeRecord? last;

  /// 当前面板版本是否自带自更新能力（低于 [minSelfUpgradeVersion] 只能手工升）。
  bool get supportsSelfUpgrade =>
      comparePanelVersions(currentVersion, minSelfUpgradeVersion) >= 0;

  bool get hasVersionNumber =>
      RegExp(r'\d').hasMatch(currentVersion) &&
      currentVersion.trim().isNotEmpty;

  factory PanelUpgradeInfo.fromJson(Map<String, dynamic> json) {
    final rawLast = json['last'];
    return PanelUpgradeInfo(
      currentVersion: (json['current_version'] as String?)?.trim() ?? '',
      latestVersion: (json['latest_version'] as String?)?.trim() ?? '',
      upgradeEnabled: json['upgrade_enabled'] == true,
      canUpgrade: json['can_upgrade'] == true,
      reason: (json['reason'] as String?)?.trim() ?? '',
      last: rawLast is Map<String, dynamic>
          ? UpgradeRecord.fromJson(rawLast)
          : null,
    );
  }
}

/// `GET /api/system/upgrade/status` 与 `POST /api/system/upgrade`(202) 的载荷。
class UpgradeStatus {
  const UpgradeStatus({
    required this.state,
    required this.phaseText,
    required this.from,
    required this.to,
    required this.errorCode,
    required this.logTail,
  });

  /// 状态机 state（idle / requested / verifying / stopping / backing_up /
  /// replacing / starting / health_check / done / failed / rolled_back / interrupted）。
  final String state;

  /// 服务端写的中文阶段文案（空时由 [upgradeStateLabel] 兜底）。
  final String phaseText;

  final String from;
  final String to;
  final String errorCode;

  /// 日志尾（最多 20 行，服务端保证是数组，不会为 null）。
  final List<String> logTail;

  /// 阶段中文：优先用服务端写的 phase_text（它含具体版本号等信息），
  /// 为空时才用状态码映射——不自己拼装，避免与服务端说法不一致。
  String get phaseLabel =>
      phaseText.isNotEmpty ? phaseText : upgradeStateLabel(state);

  factory UpgradeStatus.fromJson(Map<String, dynamic> json) {
    final rawTail = json['log_tail'];
    return UpgradeStatus(
      state: (json['state'] as String?)?.trim() ?? '',
      phaseText: (json['phase_text'] as String?)?.trim() ?? '',
      from: (json['from'] as String?)?.trim() ?? '',
      to: (json['to'] as String?)?.trim() ?? '',
      errorCode: (json['error_code'] as String?)?.trim() ?? '',
      logTail: rawTail is List
          ? rawTail.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }
}

/// 一条升级历史（对齐 `internal/model.UpgradeRecord`）。
class UpgradeRecord {
  const UpgradeRecord({
    required this.id,
    required this.fromVersion,
    required this.toVersion,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.durationMs,
    required this.errorCode,
    required this.logPath,
  });

  final int id;
  final String fromVersion;
  final String toVersion;

  /// in_progress | done | failed | rolled_back | interrupted
  final String status;

  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int durationMs;
  final String errorCode;
  final String logPath;

  factory UpgradeRecord.fromJson(Map<String, dynamic> json) {
    final rawStarted = json['started_at'];
    final rawFinished = json['finished_at'];
    return UpgradeRecord(
      id: (json['id'] as num?)?.toInt() ?? 0,
      fromVersion: (json['from_version'] as String?)?.trim() ?? '',
      toVersion: (json['to_version'] as String?)?.trim() ?? '',
      status: (json['status'] as String?)?.trim() ?? '',
      startedAt: rawStarted is String
          ? DateTime.tryParse(rawStarted)?.toLocal()
          : null,
      finishedAt: rawFinished is String
          ? DateTime.tryParse(rawFinished)?.toLocal()
          : null,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      errorCode: (json['error_code'] as String?)?.trim() ?? '',
      logPath: (json['log_path'] as String?)?.trim() ?? '',
    );
  }
}

/// `GET /api/system/upgrades` 的一页。
class UpgradeHistory {
  const UpgradeHistory({
    required this.items,
    required this.total,
    this.endpointMissing = false,
  });

  final List<UpgradeRecord> items;
  final int total;

  /// 端点还没上线（404）。此时按「空历史」展示，不把「还没做」报成「坏了」。
  final bool endpointMissing;

  bool get hasMore => items.length < total;

  factory UpgradeHistory.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return UpgradeHistory(
      items: rawItems is List
          ? rawItems
              .whereType<Map<String, dynamic>>()
              .map(UpgradeRecord.fromJson)
              .toList(growable: false)
          : const <UpgradeRecord>[],
      total: (json['total'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 版本比较：复用 updater 的 [SemVer]。
///
/// 不自己写一份字符串比较：字典序会把 `0.10.0` 判成小于 `0.9.0`，
/// 这个坑已经在 App 更新逻辑里踩过一次，没必要在面板升级里再踩一次。
int comparePanelVersions(String a, String b) {
  final left = _trimV(a);
  final right = _trimV(b);
  if (left.isEmpty && right.isEmpty) return 0;
  if (left.isEmpty) return -1;
  if (right.isEmpty) return 1;
  return SemVer.parse(left).compareTo(SemVer.parse(right));
}

bool samePanelVersion(String a, String b) {
  final left = _trimV(a);
  final right = _trimV(b);
  if (left.isEmpty || right.isEmpty) return false;
  if (left == right) return true;
  return SemVer.parse(left) == SemVer.parse(right);
}

/// 展示用：补 `v` 前缀（服务端与 GitHub tag 有的带、有的不带）。
String withVersionPrefix(String version) {
  final value = version.trim();
  if (value.isEmpty) return value;
  final lower = value.toLowerCase();
  if (lower.startsWith('v')) return value;
  if (!RegExp(r'^\d').hasMatch(value)) return value;
  return 'v$value';
}

/// 展示用版本号：空值如实说「未知」，而不是渲染出「→ v0.4.0」这种半截文案。
String displayVersion(String raw) {
  final value = raw.trim();
  return value.isEmpty ? '未知' : withVersionPrefix(value);
}

String _trimV(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('v') || value.startsWith('V')) {
    value = value.substring(1);
  }
  return value.trim();
}

/// 状态机 state → 中文阶段（7 个阶段 + 3 个终态）。
///
/// 只在服务端 `phase_text` 为空时兜底：服务端写的是「停止服务 fleetboard」这种
/// 带对象的具体说法，客户端凭状态码只能给出笼统标签，不能覆盖它。
String upgradeStateLabel(String state) {
  return switch (state.trim()) {
    'requested' => '升级已受理',
    'verifying' => '正在准备',
    'stopping' => '停止服务',
    'backing_up' => '正在准备',
    'replacing' => '替换文件',
    'starting' => '启动新版本',
    'health_check' => '健康检查中',
    'done' => '升级完成',
    'failed' => '升级失败',
    'rolled_back' => '已回滚到旧版本',
    'interrupted' => '升级中断',
    '' || 'idle' => '当前没有升级任务',
    _ => '未知状态（$state）',
  };
}

/// 终态：出现即不再轮询。
bool isTerminalUpgradeState(String state) {
  return switch (state.trim()) {
    'done' || 'failed' || 'rolled_back' || 'interrupted' => true,
    _ => false,
  };
}

/// 是否有升级在途（非 idle 且非终态）。
bool isUpgradeInFlight(String state) {
  final value = state.trim();
  return value.isNotEmpty && value != 'idle' && !isTerminalUpgradeState(value);
}

/// 错误码 → 中文。码值取自 `internal/upgrade/upgrade.sh` 与 api 层的约定。
String describeUpgradeErrorCode(String code) {
  return switch (code.trim()) {
    'db_backup_failed' => '数据库备份失败，已回滚',
    'replace_failed' => '替换文件失败，已回滚',
    'start_failed' => '新版本启动失败，已回滚',
    'health_check_failed' => '新版本健康检查未通过，已回滚',
    'env_changed' => '升级期间 .env 被外部改动，已中止',
    'upgrade_failed' => '升级失败，已回滚',
    'busy' => '已有升级任务在进行',
    'disabled' => '本实例不支持自更新',
    '' => '未记录错误码',
    _ => code.trim(),
  };
}

/// 历史记录 status → 中文。
String upgradeRecordStatusLabel(String status) {
  return switch (status.trim()) {
    'in_progress' => '进行中',
    'done' => '成功',
    'failed' => '失败',
    'rolled_back' => '已回滚',
    'interrupted' => '中断',
    '' => '未知',
    _ => status.trim(),
  };
}

/// `MM-dd HH:mm`（列表里够用，年份留给详情；升级是低频操作）。
String formatUpgradeTime(DateTime? time) {
  if (time == null) return '时间未知';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

/// 耗时：毫秒 → `12.3s` / `1分05s`；未记录时如实说「未记录」。
String formatUpgradeDuration(int durationMs) {
  if (durationMs <= 0) return '未记录';
  if (durationMs < 60 * 1000) {
    return '${(durationMs / 1000).toStringAsFixed(1)}s';
  }
  final totalSeconds = durationMs ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes分${seconds.toString().padLeft(2, '0')}s';
}
