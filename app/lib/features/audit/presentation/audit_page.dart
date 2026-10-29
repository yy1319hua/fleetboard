import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_dot.dart';
import '../application/audit_notifier.dart';
import '../data/audit_repository.dart';
import '../domain/audit_entry.dart';

/// 操作审计（只读）。
///
/// 三个必须讲清楚的事实，页面上都直接写出来，不让用户自己猜：
///  1. 后端只有 `limit` 一个参数（没有 offset），所以「加载更多」是**把窗口加大
///     重拉**，上限 500 条；更早的记录去 Web 端查。
///  2. 顶部筛选是**对已加载这一窗数据的客户端筛选**，不是服务端过滤。
///  3. 后端只记录 `ok / fail`，不记状态码数字，所以这里只显示成功/失败。
class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  /// null = 不筛选。值取自数据里真实出现过的方法。
  String? _method;

  /// null = 不筛选；'ok' / 'fail'。
  String? _result;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(auditProvider);
    final notifier = ref.read(auditProvider.notifier);

    final filtered = state.items.where((entry) {
      if (_method != null && entry.method != _method) return false;
      if (_result != null && entry.result.toLowerCase() != _result) return false;
      return true;
    }).toList(growable: false);

    final filtering = _method != null || _result != null;

    // 复用 AsyncStateView 的四态：把「加载中 / 整页失败 / 有数据」翻译成 AsyncValue。
    final AsyncValue<List<AuditEntry>> value;
    if (state.loading) {
      value = const AsyncValue<List<AuditEntry>>.loading();
    } else if (state.error != null && state.items.isEmpty) {
      value = AsyncValue<List<AuditEntry>>.error(
        ApiException(message: state.error!),
        StackTrace.empty,
      );
    } else {
      value = AsyncValue<List<AuditEntry>>.data(filtered);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('操作审计'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: notifier.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _AuditNotice(
            loaded: state.items.length,
            limit: state.limit,
            filtering: filtering,
            shown: filtered.length,
          ),
          _FilterBar(
            methods: _methodChoices(state.items, _method),
            selectedMethod: _method,
            selectedResult: _result,
            onMethod: (method) => setState(() => _method = method),
            onResult: (result) => setState(() => _result = result),
          ),
          Expanded(
            child: AsyncStateView<List<AuditEntry>>(
              value: value,
              loadingHint: '正在读取审计表…',
              onRetry: notifier.load,
              emptyHint: state.items.isNotEmpty
                  ? '当前筛选条件下没有记录（已在 ${state.items.length} 条已加载数据里筛过）。'
                      '把筛选改回「全部」看看，或加载更多条数后再筛。'
                  : '还没有审计记录。App 与 Web 的每个已鉴权请求都会由中间件写一条；'
                      '刚部署完的话，先做一次操作（打开容器、改配置）再回来看。',
              builder: (entries) => RefreshIndicator(
                onRefresh: notifier.refresh,
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: entries.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index == entries.length) {
                      return _ListFooter(state: state, notifier: notifier);
                    }
                    return _AuditTile(
                      entry: entries[index],
                      onTap: () => _showDetail(entries[index]),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 筛选项来自**数据里真实出现过的方法**：后端没有过滤参数，
  /// 列出一堆数据里根本没有的方法（比如全是 GET 却给个 DELETE 筛选项）
  /// 只会让用户点出一个空列表。
  static List<String> _methodChoices(List<AuditEntry> items, String? current) {
    final set = <String>{};
    for (final entry in items) {
      if (entry.method != '—') set.add(entry.method);
    }
    if (current != null) set.add(current);
    final list = set.toList()..sort();
    return list;
  }

  void _showDetail(AuditEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AuditDetailSheet(entry: entry),
    );
  }
}

class _AuditNotice extends StatelessWidget {
  const _AuditNotice({
    required this.loaded,
    required this.limit,
    required this.filtering,
    required this.shown,
  });

  final int loaded;
  final int limit;
  final bool filtering;
  final int shown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        filtering
            ? '已加载 $loaded 条（请求窗口 $limit 条），当前筛选命中 $shown 条。'
                '筛选只作用于已加载的数据——后端没有过滤参数。'
            : '时间倒序，后端只接受 limit（上限 ${AuditRepository.maxLimit} 条），'
                '当前窗口 $limit 条。更早的记录请到 Web 端查询。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.methods,
    required this.selectedMethod,
    required this.selectedResult,
    required this.onMethod,
    required this.onResult,
  });

  final List<String> methods;
  final String? selectedMethod;
  final String? selectedResult;
  final ValueChanged<String?> onMethod;
  final ValueChanged<String?> onResult;

  @override
  Widget build(BuildContext context) {
    // 高度给足 56：ChoiceChip 在 compact 密度下约 40–48dp，约束太紧会出溢出条纹。
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip('全部方法', selectedMethod == null, () => onMethod(null)),
          for (final method in methods)
            _chip(method, selectedMethod == method, () => onMethod(method)),
          const _Sep(),
          _chip('全部结果', selectedResult == null, () => onResult(null)),
          _chip('成功', selectedResult == 'ok', () => onResult('ok')),
          _chip('失败', selectedResult == 'fail', () => onResult('fail')),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Center(
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 14),
      child: VerticalDivider(width: 1),
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.entry, required this.onTap});

  final AuditEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: StatusDot(entry.ok ? StatusKind.ok : StatusKind.danger),
      title: Row(
        children: [
          _MethodBadge(method: entry.method),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.detail.isEmpty ? entry.route : entry.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${formatAuditTime(entry.createdAt)} · 用户 #${entry.userId}'
        '${entry.serverId == null ? ' · 服务器未记录' : ' · 服务器 #${entry.serverId}'}'
        ' · ${entry.resultLabel}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: onTap,
    );
  }
}

class _MethodBadge extends StatelessWidget {
  const _MethodBadge({required this.method});

  final String method;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (method) {
      'GET' => StatusKind.info,
      'POST' => StatusKind.ok,
      'DELETE' => StatusKind.danger,
      'PUT' || 'PATCH' => StatusKind.warn,
      _ => StatusKind.idle,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color, size: 6),
        const SizedBox(width: 5),
        Text(
          method,
          style: theme.textTheme.labelSmall?.copyWith(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// 列表页脚：加载更多 / 已到上限 / 这一档加载失败。
class _ListFooter extends StatelessWidget {
  const _ListFooter({required this.state, required this.notifier});

  final AuditState state;
  final AuditNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (state.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              '加载更多失败：${state.loadMoreError}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: notifier.loadMore,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (state.atCap) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Text(
          '已到 ${AuditRepository.maxLimit} 条上限（后端单次最多给这么多）。'
          '更早的记录请在 Web 端按条件查询。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    if (state.canLoadMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: OutlinedButton.icon(
          onPressed: notifier.loadMore,
          icon: const Icon(Icons.expand_more, size: 18),
          label: Text('加载更多（${
              state.limit + 100 > AuditRepository.maxLimit ? AuditRepository.maxLimit : state.limit + 100
          } 条窗口）'),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Text(
        '已经到底了（共 ${state.items.length} 条）。',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 详情层：把后端原始字段一个不落地列出来（排查时这些字段就是证据）。
class _AuditDetailSheet extends StatelessWidget {
  const _AuditDetailSheet({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('id', '${entry.id}'),
      ('action', entry.action),
      ('detail', entry.detail),
      ('result', entry.result.isEmpty ? '—' : entry.result),
      ('user_id', '${entry.userId}'),
      ('server_id', entry.serverId == null ? 'null（未记录）' : '${entry.serverId}'),
      ('created_at（原始）', entry.createdAt == null
          ? '—'
          : entry.createdAt!.toUtc().toIso8601String()),
      ('created_at（本地）', formatAuditTimeFull(entry.createdAt)),
      ('method（从 action 拆出）', entry.method),
      ('路由模板（从 action 拆出）', entry.route),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(entry.ok ? StatusKind.ok : StatusKind.danger),
              const SizedBox(width: 8),
              Text(
                '${entry.method} · ${entry.resultLabel}',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.$1,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          SelectableText(
                            row.$2.isEmpty ? '（空）' : row.$2,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final json = const JsonEncoder.withIndent('  ').convert(
                      <String, dynamic>{
                        'id': entry.id,
                        'action': entry.action,
                        'detail': entry.detail,
                        'result': entry.result,
                        'user_id': entry.userId,
                        'server_id': entry.serverId,
                        'created_at': entry.createdAt?.toUtc().toIso8601String(),
                      },
                    );
                    // 先取 messenger 再 pop：pop 之后本层的 context 已失效。
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: json));
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('已复制这条审计的原始 JSON')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制原始 JSON'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
