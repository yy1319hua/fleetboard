import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/async_state_view.dart';
import '../application/upgrade_run_notifier.dart';
import '../data/upgrade_repository.dart';
import '../domain/panel_upgrade.dart';
import 'upgrade_history_page.dart';

/// 面板自更新页。
///
/// 这个页面的难点不在表单，而在「升级期间面板会消失 10–30 秒」：
/// 所有请求都可能失败，而失败本身**不构成任何结论**。所以整个交互围绕一条铁律：
/// 升级窗口内的一切请求失败都被吞掉，界面只按 health 版本 + 状态机终态 + 已过时间
/// 说话；超过容忍窗口才把判断权交给用户（并给出可复制的手工命令），绝不自动重试。
class PanelUpgradePage extends ConsumerStatefulWidget {
  const PanelUpgradePage({super.key});

  @override
  ConsumerState<PanelUpgradePage> createState() => _PanelUpgradePageState();
}

class _PanelUpgradePageState extends ConsumerState<PanelUpgradePage> {
  /// 触发请求在途（这一瞬间在升级窗口之外，失败必须让用户看见）。
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    // App 重启会丢掉轮询，但服务器上的升级不会因此停下：
    // 进页面先问一次状态，若有在途升级就接手继续观察。
    Future.microtask(_adoptRunningUpgrade);
  }

  Future<void> _adoptRunningUpgrade() async {
    final status = await ref.read(upgradeRepositoryProvider).statusOrNull();
    if (!mounted || status == null) return;
    if (!isUpgradeInFlight(status.state)) return;
    ref.read(upgradeRunProvider.notifier).adopt(status);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final infoAsync = ref.watch(panelUpgradeInfoProvider);
    final run = ref.watch(upgradeRunProvider);

    // 升级刚落到终态：刷新版本信息（当前版本/最新版本/上次记录都变了）。
    ref.listen<UpgradeRunState?>(upgradeRunProvider, (previous, next) {
      final wasRunning = previous != null && !previous.phase.isTerminal;
      if (next != null &&
          next.phase.isTerminal &&
          (previous == null || wasRunning)) {
        ref.invalidate(panelUpgradeInfoProvider);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('面板更新'),
        actions: <Widget>[
          // 升级窗口内不提供「刷新版本信息」：这段时间面板正在停机，
          // 这个按钮必然失败，摆在那里只会把用户引向一个错误页。
          if (run == null || run.phase.isTerminal)
            IconButton(
              tooltip: '刷新版本信息',
              onPressed: () => ref.invalidate(panelUpgradeInfoProvider),
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: '升级历史',
            onPressed: _openHistory,
            icon: const Icon(Icons.history),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 240),
            child: AsyncStateView<PanelUpgradeInfo>(
              value: infoAsync,
              emptyHint: '没有拿到面板版本信息。可以点重试再问一次。',
              onRetry: () => ref.invalidate(panelUpgradeInfoProvider),
              loadingHint: '正在读取面板版本…',
              builder: (info) => _buildBody(context, info, run),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '面板自更新会替换正在运行的面板程序。升级失败会自动回滚到升级前的版本。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    PanelUpgradeInfo info,
    UpgradeRunState? run,
  ) {
    final runInFlight = run != null && !run.phase.isTerminal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _VersionCard(info: info),
        const SizedBox(height: AppSpacing.md),
        if (!info.upgradeEnabled)
          _buildDisabledCard(context, info)
        else if (!info.supportsSelfUpgrade)
          _buildTooOldCard(context, info)
        else if (info.canUpgrade)
          _buildUpgradeCard(context, info, runInFlight: runInFlight)
        else
          _buildNotUpgradableCard(context, info, runInFlight: runInFlight),
        if (run != null) ...[
          const SizedBox(height: AppSpacing.md),
          _RunPanel(
            state: run,
            onRecheck: () => ref.read(upgradeRunProvider.notifier).recheck(),
            onDismiss: () => ref.read(upgradeRunProvider.notifier).dismiss(),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: _openHistory,
          icon: const Icon(Icons.history, size: 18),
          label: const Text('查看升级历史'),
        ),
      ],
    );
  }

  /// 开关关闭：整页只读，且**不给灰按钮**。
  ///
  /// 灰按钮的文法是「现在不行，等一会儿再说」，而这里缺的是一个服务端配置，
  /// 用户再等一年也不会变可用。所以什么都不给，只把「改哪里、怎么生效」写清楚。
  Widget _buildDisabledCard(BuildContext context, PanelUpgradeInfo info) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.info_outline, size: 18, color: AppColors.info),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('本实例未开启面板自更新', style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '面板自更新会替换正在运行的二进制，因此服务端默认关闭。'
              '要在这里升级，需要先在服务器上开启开关，然后重启面板服务：',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _CommandBlock(command: '$upgradeEnabledEnvKey=1'),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '写入 /opt/fleetboard/.env 后执行 sudo systemctl restart fleetboard。',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '只用命令行升级也可以，随时可用：',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
            ),
            const SizedBox(height: AppSpacing.xs),
            const _CommandBlock(command: manualUpgradeCommand),
          ],
        ),
      ),
    );
  }

  /// 面板版本低于 App 内置的最低支持版本：先手升一次，之后 App 内就能升。
  Widget _buildTooOldCard(BuildContext context, PanelUpgradeInfo info) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.upgrade, size: 18, color: AppColors.warn),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('当前面板版本不支持在 App 内升级',
                      style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '面板自更新从 ${withVersionPrefix(minSelfUpgradeVersion)} 起才提供；'
              '当前是 ${displayVersion(info.currentVersion)}。'
              '请先在服务器上手工升级一次，之后就能回到这里一键升级。',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _CommandBlock(command: manualUpgradeCommand),
          ],
        ),
      ),
    );
  }

  Widget _buildUpgradeCard(
    BuildContext context,
    PanelUpgradeInfo info, {
    required bool runInFlight,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('可以升级', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${displayVersion(info.currentVersion)} → '
              '${displayVersion(info.latestVersion)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: AppFonts.mono,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (runInFlight)
              // 正在升级时按钮必须是「不存在」而不是「灰着」：
              // 用户已经点过并确认过，这里再摆一个按不动的按钮只会让他反复试探。
              Text(
                '升级正在进行中，完成前不会再触发第二次。',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
              )
            else
              FilledButton(
                onPressed: _starting ? null : () => _startUpgrade(info),
                child: _starting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.textInverse,
                        ),
                      )
                    : Text('升级到 ${withVersionPrefix(info.latestVersion)}'),
              ),
          ],
        ),
      ),
    );
  }

  /// 不能升级但开关是开的：服务端已经给出中文原因（已是最新 / 有任务在跑 / 环境不满足），
  /// 客户端原样展示，不做二次推断，也不再摆按钮。
  Widget _buildNotUpgradableCard(
    BuildContext context,
    PanelUpgradeInfo info, {
    required bool runInFlight,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('暂时无法升级', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              info.reason.isEmpty ? '服务端未说明原因' : info.reason,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: AppSpacing.md),
            if (runInFlight)
              Text(
                '升级进行中，结束后会自动刷新版本信息。',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
              )
            else
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(panelUpgradeInfoProvider),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新检查'),
              ),
          ],
        ),
      ),
    );
  }

  void _openHistory() {
    // 用 MaterialPageRoute 而不是路由表：历史页是本功能内部的一层，
    // 不依赖外部路由注册也能跳（主理人接线后仍可改成 context.push）。
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const UpgradeHistoryPage(),
      ),
    );
  }

  /// 触发升级：二次确认（讲清停机代价）→ 输入登录密码 → POST。
  Future<void> _startUpgrade(PanelUpgradeInfo info) async {
    final confirmed = await _confirmUpgrade(info);
    if (confirmed != true || !mounted) return;
    final password = await _askPassword();
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _starting = true);
    try {
      final status = await ref.read(upgradeRepositoryProvider).trigger(
            password: password,
            opId: newUpgradeOpId(),
            targetVersion: info.latestVersion,
          );
      if (!mounted) return;
      ref.read(upgradeRunProvider.notifier).begin(
            fromVersion: info.currentVersion,
            targetVersion: info.latestVersion,
            initial: status,
          );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('升级已开始，接下来 10–30 秒可能连不上面板，属正常现象'),
          duration: Duration(seconds: 4),
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      // 触发阶段在升级窗口之外：这里失败必须说清楚，否则用户会以为升级已在跑。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_describeTriggerError(e)),
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<bool?> _confirmUpgrade(PanelUpgradeInfo info) {
    final theme = Theme.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('升级到 ${withVersionPrefix(info.latestVersion)}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${displayVersion(info.currentVersion)} → '
              '${displayVersion(info.latestVersion)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: AppFonts.mono,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const _ConfirmBullet('预计停机 10–30 秒，期间 App 会暂时连不上面板。'),
            const _ConfirmBullet('升级期间请不要关闭服务器电源或强制重启。'),
            const _ConfirmBullet('新版本起不来时会自动回滚到当前版本，数据不会丢。'),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askPassword() async {
    final controller = TextEditingController();
    var obscure = true;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('确认是本人操作'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text('升级会替换正在运行的面板程序，请输入登录密码后再执行。'),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                obscureText: obscure,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '登录密码',
                  suffixIcon: IconButton(
                    onPressed: () => setDialogState(() => obscure = !obscure),
                    icon: Icon(
                      obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    tooltip: obscure ? '显示密码' : '隐藏密码',
                  ),
                ),
                onChanged: (_) => setDialogState(() {}),
                onSubmitted: (value) {
                  if (value.isNotEmpty) Navigator.of(ctx).pop(value);
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              // 空密码不给点：这次请求一定会被服务端拒绝，没必要发出去。
              onPressed: controller.text.isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(controller.text),
              child: const Text('开始升级'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  /// 触发失败的文案：这里要区分「没执行」和「执行了但在升级中」，两者后续动作完全不同。
  String _describeTriggerError(Object error) {
    final inner = error is DioException ? error.error : error;
    if (inner is ApiException) {
      final message = inner.message.trim();
      return switch (inner.code) {
        401 => '未执行升级：${message.isEmpty ? '密码错误' : message}',
        409 => '未执行升级：${message.isEmpty ? '服务端拒绝了本次请求' : message}',
        404 => '本实例未开启面板自更新，升级请求未被受理',
        400 => '升级请求参数不被接受：${message.isEmpty ? '请升级 App 后重试' : message}',
        _ => describeApiError(error),
      };
    }
    return describeApiError(error);
  }
}

/// 版本卡：当前 / 最新 / 上次升级结果。
class _VersionCard extends StatelessWidget {
  const _VersionCard({required this.info});

  final PanelUpgradeInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = info.last;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _VersionRow(
              label: '当前版本',
              value: withVersionPrefix(info.currentVersion),
            ),
            const SizedBox(height: AppSpacing.sm),
            _VersionRow(
              label: '最新版本',
              value: withVersionPrefix(info.latestVersion),
              highlight: info.canUpgrade,
            ),
            if (!info.upgradeEnabled) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                '自更新未开启',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
              ),
            ],
            if (last != null) ...[
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '上次升级：'
                '${last.fromVersion.isEmpty ? '未知' : last.fromVersion} → '
                '${last.toVersion.isEmpty ? '未知' : last.toVersion}'
                ' · ${upgradeRecordStatusLabel(last.status)}'
                ' · ${formatUpgradeTime(last.startedAt)}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              if (last.errorCode.isNotEmpty)
                Text(
                  '错误码 ${last.errorCode} · '
                  '${describeUpgradeErrorCode(last.errorCode)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.warn),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '未知' : value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: AppFonts.mono,
              color: highlight ? AppColors.accent : AppColors.text,
            ),
          ),
        ),
      ],
    );
  }
}

/// 升级进行中 / 结束后的状态面板。
class _RunPanel extends StatelessWidget {
  const _RunPanel({
    required this.state,
    required this.onRecheck,
    required this.onDismiss,
  });

  final UpgradeRunState state;
  final VoidCallback onRecheck;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _color;
    final status = state.status;
    final logTail = status?.logTail ?? const <String>[];
    final showManualHelp = state.phase == UpgradeRunPhase.suspectedFailure ||
        state.phase == UpgradeRunPhase.needsAttention;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(_icon, size: 18, color: color),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    state.phaseLabel,
                    style: theme.textTheme.titleSmall?.copyWith(color: color),
                  ),
                ),
                Text(
                  // 刚受理时不足 1s，直接说「不到 1s」；用历史记录的格式化函数会把 0
                  // 说成「未记录」，那是历史表里没有耗时的语义，两者不能混用。
                  state.elapsed.inSeconds < 1
                      ? '已用不到 1s'
                      : '已用 ${formatUpgradeDuration(state.elapsed.inMilliseconds)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.faint),
                ),
              ],
            ),
            if (!state.phase.isTerminal) ...[
              const SizedBox(height: AppSpacing.md),
              // 服务端不提供百分比，就绝不编一个进度条出来：不确定的进度条
              // 比没有进度条更糟（用户会盯着它算还有多久）。
              LinearProgressIndicator(
                minHeight: 3,
                backgroundColor: AppColors.s2,
                color: color,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              '${displayVersion(state.fromVersion)} → '
              '${displayVersion(state.targetVersion)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: AppFonts.mono,
                color: AppColors.text,
              ),
            ),
            if (status != null && state.phase == UpgradeRunPhase.running) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                '服务器阶段：${status.phaseLabel}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
            ],
            if (status != null && status.errorCode.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                '错误码 ${status.errorCode} · ${describeUpgradeErrorCode(status.errorCode)}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.warn),
              ),
            ],
            if (state.hint != null && state.hint!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                state.hint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  // 等待重启是「预期内的灰字」，失败提示才用告警色。
                  color: state.phase == UpgradeRunPhase.waitingRestart
                      ? AppColors.muted
                      : color,
                ),
              ),
            ],
            if (showManualHelp) ...[
              const SizedBox(height: AppSpacing.sm),
              const _CommandBlock(command: manualUpgradeCommand),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '升级只是替换面板程序，容器与业务数据不受影响；先看状态再决定是否重试。',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
              ),
            ],
            if (logTail.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _LogTailPanel(lines: logTail),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                if (state.phase.isTerminal)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onRecheck,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重新检查'),
                    ),
                  ),
                if (state.phase.isTerminal)
                  const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextButton(
                    onPressed: onDismiss,
                    child: const Text('收起'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData get _icon {
    return switch (state.phase) {
      UpgradeRunPhase.success => Icons.check_circle_outline,
      UpgradeRunPhase.rolledBack => Icons.undo,
      UpgradeRunPhase.suspectedFailure => Icons.error_outline,
      UpgradeRunPhase.needsAttention => Icons.help_outline,
      UpgradeRunPhase.waitingRestart => Icons.hourglass_empty,
      _ => Icons.sync,
    };
  }

  Color get _color {
    return switch (state.phase) {
      UpgradeRunPhase.success => AppColors.ok,
      UpgradeRunPhase.rolledBack => AppColors.warn,
      UpgradeRunPhase.suspectedFailure => AppColors.danger,
      UpgradeRunPhase.needsAttention => AppColors.warn,
      _ => AppColors.info,
    };
  }
}

/// 日志尾：等宽小字号、自动滚到底、可全屏看。
class _LogTailPanel extends StatefulWidget {
  const _LogTailPanel({required this.lines});

  final List<String> lines;

  @override
  State<_LogTailPanel> createState() => _LogTailPanelState();
}

class _LogTailPanelState extends State<_LogTailPanel> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToBottomSoon();
  }

  @override
  void didUpdateWidget(covariant _LogTailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 每次新日志到达都跟到末尾：升级时用户盯的就是「最后一行停在哪一步」。
    if (oldWidget.lines.length != widget.lines.length) _scrollToBottomSoon();
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '升级日志（最后 ${widget.lines.length} 行）',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
            ),
            TextButton(
              onPressed: _openFullScreen,
              child: const Text('全屏'),
            ),
          ],
        ),
        Container(
          height: 140,
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.s2,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: ListView.builder(
            controller: _controller,
            itemCount: widget.lines.length,
            itemBuilder: (context, index) => Text(
              widget.lines[index],
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: AppFonts.mono,
                fontSize: 11,
                height: 1.35,
                color: AppColors.muted,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openFullScreen() {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('升级日志'),
            actions: <Widget>[
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: SelectableText(
                widget.lines.join('\n'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: AppFonts.mono,
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.text,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 可复制的命令块。
///
/// 升级失败时用户唯一的出路是 SSH 上服务器，所以这些命令必须能一键复制：
/// 手抄 `sudo /opt/fleetboard/upgrade.sh` 很容易漏斜杠，而手机键盘改起来很烦。
class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.xs,
        0,
        AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.s2,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SelectableText(
              command,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: AppFonts.mono,
                fontSize: 12,
                color: AppColors.text,
              ),
            ),
          ),
          IconButton(
            tooltip: '复制命令',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('命令已复制'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.copy_all_outlined, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ConfirmBullet extends StatelessWidget {
  const _ConfirmBullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 6),
            child: Icon(Icons.circle, size: 5, color: AppColors.muted),
          ),
          Expanded(
            child: Text(
              text,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}
