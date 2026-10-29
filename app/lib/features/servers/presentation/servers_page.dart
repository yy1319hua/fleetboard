import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../overview/application/overview_notifier.dart';
import '../../overview/domain/bootstrap.dart';
import '../../settings/presentation/settings_common.dart';
import '../application/servers_provider.dart';
import '../data/servers_repository.dart';

/// 服务器纳管列表（M11.1）。
///
/// 每个条目可直接「测试连接」与「删除」——这两件事以前只能回 Web 做，
/// 而它们恰好是排障时最常用的（连不上、机器下线了要摘掉）。
class ServersPage extends ConsumerStatefulWidget {
  const ServersPage({super.key});

  @override
  ConsumerState<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends ConsumerState<ServersPage> {
  /// 正在测试/删除的服务器 id，用于禁用该行操作，避免连点重复执行。
  int? _busyId;

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器纳管'),
        actions: <Widget>[
          IconButton(
            onPressed: () => _openWizard(),
            icon: const Icon(Icons.add),
            tooltip: '新增服务器',
          ),
        ],
      ),
      body: servers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => SettingsLoadError(
          title: '读取服务器列表失败',
          message: describeApiError(e),
          onRetry: () => ref.invalidate(serversProvider),
        ),
        data: _list,
      ),
    );
  }

  Widget _list(List<Server> list) {
    if (list.isEmpty) return _empty();
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(serversProvider);
        // 等新值到达再收起指示器，否则会有「刷新了个寂寞」的观感。
        await ref.read(serversProvider.future);
      },
      child: ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (BuildContext context, int i) {
          final s = list[i];
          final busy = _busyId == s.id;
          return _ServerTile(
            server: s,
            busy: busy,
            onOpen: () => context.push('/servers/${s.id}'),
            onTest: () => _test(s),
            onDelete: () => _confirmDelete(s),
          );
        },
      ),
    );
  }

  Widget _empty() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.dns_outlined, size: 32, color: AppColors.faint),
            const SizedBox(height: AppSpacing.md),
            Text('还没有纳管服务器', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '新增后即可在总览看到它的 CPU、内存与磁盘。',
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () => _openWizard(),
              child: const Text('新增服务器'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openWizard() async {
    final created = await context.push<bool>('/settings/servers/new');
    if (created == true && mounted) {
      ref.invalidate(serversProvider);
      ref.invalidate(overviewProvider);
    }
  }

  Future<void> _test(Server s) async {
    if (_busyId != null) return;
    setState(() => _busyId = s.id);
    try {
      await ref.read(serversRepositoryProvider).test(s.id);
      if (!mounted) return;
      showToast(context, '${s.name} 连接正常');
      ref.invalidate(serversProvider);
      ref.invalidate(overviewProvider);
    } on Object catch (e) {
      if (!mounted) return;
      showToast(context, '${s.name} 连接失败：${describeApiError(e)}',
          isError: true);
      ref.invalidate(serversProvider);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _confirmDelete(Server s) async {
    if (_busyId != null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: Text('删除「${s.name}」'),
            content: const Text(
              '将删除这台服务器的纳管记录、加密凭据与历史指标。\n'
              '服务器本身不受影响，可重新添加。此操作不可撤销。',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: AppColors.danger),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed != true || !mounted) return;

    setState(() => _busyId = s.id);
    try {
      await ref.read(serversRepositoryProvider).remove(s.id);
      if (!mounted) return;
      // 详情页可能正开着这台机器：回到列表，避免停在已删除对象上继续发请求。
      if (context.canPop()) context.pop();
      ref.invalidate(serversProvider);
      ref.invalidate(overviewProvider);
      showToast(context, '已删除 ${s.name}');
    } on Object catch (e) {
      if (!mounted) return;
      showToast(context, '删除失败：${describeApiError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.busy,
    required this.onOpen,
    required this.onTest,
    required this.onDelete,
  });

  final Server server;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onTest;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = server.connectionStatus == 'online';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? AppColors.ok : AppColors.idle,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      server.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${server.sshUser}@${server.host}:${server.port}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.faint,
                        fontFamily: 'JetBrains Mono',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  icon: const Icon(Icons.more_vert,
                      size: 20, color: AppColors.faint),
                  onSelected: (String v) {
                    if (v == 'test') onTest();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'test',
                      child: Text('测试连接'),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child:
                          Text('删除', style: TextStyle(color: AppColors.danger)),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
