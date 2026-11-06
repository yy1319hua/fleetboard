import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/upgrade_repository.dart';
import '../domain/panel_upgrade.dart';

/// 失联容忍窗口。
///
/// 面板自更新的停机窗口官方口径是 10–30s，但「替换二进制 + systemd 起服务 +
/// 健康检查」在慢机器上会明显更久，再加上 Cloudflare 边缘节点的连接池回收，
/// 180s 是「正常也够用、异常也等不及」的位置。超过它就地把判断权交给用户，
/// 而不是继续无声地转圈。
const Duration upgradeUnreachableTolerance = Duration(seconds: 180);

/// 轮询间隔。
const Duration upgradePollInterval = Duration(seconds: 2);

/// 无结论轮询的总上限：防止一个残留的「进行中」状态把 App 变成永动机。
const Duration upgradePollGiveUpAfter = Duration(minutes: 10);

/// 升级过程在 App 侧的阶段。
enum UpgradeRunPhase {
  /// 已受理（202 拿到，或刚从历史里接手），还没有第一次探测结论。
  accepted,

  /// 服务还在、状态机在推进（准备 / 停服前 / 替换中…）。
  running,

  /// 探测不到服务，但仍在容忍窗口内 —— 停服重启的预期表现。
  waitingRestart,

  /// health 亲口报出目标版本。
  success,

  /// 服务活过来了，版本仍是被升级前的旧版本，且状态机已写终态。
  rolledBack,

  /// 超过容忍窗口仍探测不到服务：疑似失败，交给人工。
  suspectedFailure,

  /// 状态与版本自相矛盾，或轮询超时仍无结论：不下结论，提示人工核对。
  needsAttention,
}

extension UpgradeRunPhaseX on UpgradeRunPhase {
  bool get isTerminal => switch (this) {
        UpgradeRunPhase.success ||
        UpgradeRunPhase.rolledBack ||
        UpgradeRunPhase.suspectedFailure ||
        UpgradeRunPhase.needsAttention =>
          true,
        _ => false,
      };

  String get label => switch (this) {
        UpgradeRunPhase.accepted => '升级已受理',
        UpgradeRunPhase.running => '升级进行中',
        UpgradeRunPhase.waitingRestart => '等待服务重启',
        UpgradeRunPhase.success => '升级完成',
        UpgradeRunPhase.rolledBack => '已回滚到旧版本',
        UpgradeRunPhase.suspectedFailure => '疑似升级失败',
        UpgradeRunPhase.needsAttention => '需要人工核对',
      };
}

/// 一次升级在 App 侧的完整快照。
class UpgradeRunState {
  const UpgradeRunState({
    required this.phase,
    required this.fromVersion,
    required this.targetVersion,
    this.status,
    this.pollAttempt = 0,
    this.elapsed = Duration.zero,
    this.detail,
  });

  final UpgradeRunPhase phase;

  /// 升级前版本（判定「回滚」的对照物）。
  final String fromVersion;

  /// 目标版本（判定「成功」的对照物）。
  final String targetVersion;

  /// 最近一次成功拿到的状态（拿不到时为上一次的值，绝不因为一次失败就清空）。
  final UpgradeStatus? status;

  /// 探测不到服务的次数（「等待服务重启…第 N 次」）。
  final int pollAttempt;

  final Duration elapsed;

  /// 判定说明 / 下一步动作。
  final String? detail;

  /// 阶段文案：优先用服务端写的 phase_text（含具体版本、服务名），
  /// 只有失联态才由客户端补自己的说法——这时服务端已经没法说话了。
  String get phaseLabel {
    if (phase == UpgradeRunPhase.running) {
      return status?.phaseLabel ?? UpgradeRunPhaseX(phase).label;
    }
    return UpgradeRunPhaseX(phase).label;
  }

  /// 灰字附注（等待重启的次数 / 错误码说明 / 人工命令）。
  String? get hint {
    if (phase == UpgradeRunPhase.waitingRestart) {
      return '等待服务重启…第 $pollAttempt 次';
    }
    return detail;
  }
}

/// 升级编排（客户端侧）：触发后开始轮询，用「health 版本 + 状态机终态 + 已过时间」
/// 三者共同判定，**不用 HTTP 状态码做判据**。
class UpgradeRunNotifier extends StateNotifier<UpgradeRunState?> {
  UpgradeRunNotifier(this._repository) : super(null);

  final UpgradeRepository _repository;
  Timer? _timer;
  DateTime? _startedAt;
  bool _disposed = false;

  /// 开始观察一次升级。[initial] 是触发接口 202 直接带回的状态。
  void begin({
    required String fromVersion,
    required String targetVersion,
    UpgradeStatus? initial,
  }) {
    _startedAt = DateTime.now();
    state = UpgradeRunState(
      phase: UpgradeRunPhase.accepted,
      fromVersion: fromVersion,
      targetVersion: targetVersion,
      status: initial,
    );
    _schedule();
  }

  /// 页面重新进入时接手一个**服务端确实在跑**的升级。
  ///
  /// 只由页面在确认「状态机非 idle 且非终态」后调用：App 重启会丢掉轮询，
  /// 但服务器上的升级不会因此停下，用户重开 App 必须还能看到它在哪一步。
  void adopt(UpgradeStatus status) {
    if (state != null && !state!.phase.isTerminal) return;
    _startedAt = DateTime.now();
    state = UpgradeRunState(
      phase: UpgradeRunPhase.running,
      fromVersion: status.from,
      targetVersion: status.to,
      status: status,
    );
    _schedule();
  }

  /// 人工「重新检查」：只在终态（疑似失败/需核对）后由用户点击触发。
  /// 自动重试被明确禁止——服务真的起不来时，重试只会延长用户以为「还在努力」的错觉。
  Future<void> recheck() async {
    final current = state;
    if (current == null) return;
    _startedAt = DateTime.now();
    state = UpgradeRunState(
      phase: UpgradeRunPhase.accepted,
      fromVersion: current.fromVersion,
      targetVersion: current.targetVersion,
      status: current.status,
    );
    await _tick();
  }

  /// 停止轮询并收起进度面板（用户主动关闭）。
  void dismiss() {
    _timer?.cancel();
    _timer = null;
    state = null;
  }

  void _schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(upgradePollInterval, _tick);
  }

  Future<void> _tick() async {
    if (_disposed) return;
    final current = state;
    if (current == null) return;

    // 升级窗口内：两个请求的失败都在仓储层被吞成 null，这里不做任何提示。
    // 停服期间弹「网络错误」对用户是纯噪音——他刚刚被告知要等 10–30s。
    final healthVersion = await _repository.healthVersionOrNull();
    final status = await _repository.statusOrNull();
    if (_disposed || state == null) return;

    final elapsed = DateTime.now().difference(_startedAt ?? DateTime.now());
    final next = judge(
      healthVersion: healthVersion,
      status: status ?? current.status,
      elapsed: elapsed,
      fromVersion: current.fromVersion,
      targetVersion: current.targetVersion,
      pollAttempt: current.pollAttempt + (healthVersion == null ? 1 : 0),
    );
    state = next;
    if (next.phase.isTerminal) return;
    _schedule();
  }

  /// 判定核心（纯函数，便于逐条对照规格推演）。
  ///
  /// 判定顺序即优先级，四条规则与「体验成败」那张表一一对应：
  ///  ① health 报出目标版本 → 成功（唯一可信的成功信号是进程真的起来了）；
  ///  ② health 报出旧版本 + 状态机终态 → 按 error_code 说「已回滚」；
  ///  ③ health 拿不到 → 180s 内继续等（灰字报次数），超过则疑似失败、给人工命令；
  ///  ④ 其余 → 服务活着、状态机在推进，如实展示阶段。
  static UpgradeRunState judge({
    required String? healthVersion,
    required UpgradeStatus? status,
    required Duration elapsed,
    required String fromVersion,
    required String targetVersion,
    required int pollAttempt,
  }) {
    final from = fromVersion.trim();
    final to = targetVersion.trim();
    final terminal = status != null && isTerminalUpgradeState(status.state);

    UpgradeRunState build(
      UpgradeRunPhase phase, {
      String? detail,
    }) {
      return UpgradeRunState(
        phase: phase,
        fromVersion: from,
        targetVersion: to,
        status: status,
        pollAttempt: pollAttempt,
        elapsed: elapsed,
        detail: detail,
      );
    }

    // ① health 报出目标版本：二进制真的换过去且起来了，这是唯一可信的成功信号。
    if (healthVersion != null && samePanelVersion(healthVersion, to)) {
      return build(
        UpgradeRunPhase.success,
        detail: '面板已在新版本 ${withVersionPrefix(healthVersion)} 上运行。',
      );
    }

    // ② 服务活着，但报的还是升级前的版本，且状态机已经落地终态。
    if (healthVersion != null &&
        samePanelVersion(healthVersion, from) &&
        terminal) {
      if (status.state.trim() == 'done') {
        // 状态机说完成、health 却报旧版本：两边矛盾。替用户下结论（说成功或说失败）
        // 都会误导，只把事实摊开并给出核对命令。
        return build(
          UpgradeRunPhase.needsAttention,
          detail: '状态显示升级完成，但面板仍报告旧版本 '
              '${withVersionPrefix(healthVersion)}。请在服务器上执行 '
              '$manualUpgradeCommand --status 核对。',
        );
      }
      return build(
        UpgradeRunPhase.rolledBack,
        detail: describeUpgradeErrorCode(status.errorCode),
      );
    }

    // ③ 探测不到服务。停服期间这是预期表现，唯一能区分「重启中」与「起不来」的是时间。
    if (healthVersion == null) {
      if (elapsed < upgradeUnreachableTolerance) {
        return build(UpgradeRunPhase.waitingRestart);
      }
      return build(
        UpgradeRunPhase.suspectedFailure,
        detail: '面板已 ${upgradeUnreachableTolerance.inSeconds}s 没有响应，可能是升级失败。'
            '请在服务器上执行 $manualUpgradeCommand --status 查看状态，'
            '或用 journalctl -u fleetboard -n 100 查看日志。',
      );
    }

    // ③' 终态已写，但 health 报的版本既不是旧版也不是目标版（例如 dev 构建）。
    if (terminal) {
      return build(
        UpgradeRunPhase.needsAttention,
        detail: '升级已结束（${upgradeStateLabel(status.state)}），'
            '面板当前报告的版本是 ${withVersionPrefix(healthVersion)}，请人工确认。',
      );
    }

    // 轮询总上限：状态文件里的「进行中」可能是历史残留（进程异常退出时没人写终态）。
    if (elapsed >= upgradePollGiveUpAfter) {
      return build(
        UpgradeRunPhase.needsAttention,
        detail: '已观察 ${upgradePollGiveUpAfter.inMinutes} 分钟仍未拿到结论，'
            '面板可能早已结束但状态文件没更新。可执行 $manualUpgradeCommand --status 核对。',
      );
    }

    // ④ 默认：服务在，状态机在推进（例如仍在取包/校验，尚未停服）。
    return build(UpgradeRunPhase.running);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// 幂等操作 ID：`X-Client-Op-Id`。
///
/// 不引 uuid 包（新增依赖要走评审），时间戳 + 随机数在这个用途上足够：
/// 后端只用它做幂等键与审计关联，同一毫秒内两次点击的碰撞概率可忽略。
String newUpgradeOpId() {
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final rand = Random().nextInt(0x7fffffff).toRadixString(16);
  return 'up-$stamp-$rand';
}

final upgradeRunProvider =
    StateNotifierProvider.autoDispose<UpgradeRunNotifier, UpgradeRunState?>(
  (ref) => UpgradeRunNotifier(ref.watch(upgradeRepositoryProvider)),
);
