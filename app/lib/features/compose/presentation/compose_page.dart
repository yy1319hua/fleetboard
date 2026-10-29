import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_state_view.dart';
import '../application/compose_file_notifier.dart';
import '../domain/compose_models.dart';
import 'compose_file_page.dart';

/// Compose 编排 · 文件浏览页。
///
/// 页面职责只有一件：**在服务器上找到 compose 文件**。后端接口是单层目录浏览
/// （`?dir=`），所以这里做面包屑 + 下钻，而不是假装能一次列全机器上的文件。
/// 点文件进入 [ComposeFilePage]：只读全文 / 表单编辑 / 原文编辑 / 动作编排。
class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({super.key, required this.serverId});

  final int serverId;

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends ConsumerState<ComposePage> {
  /// null = 让后端用它自己的默认起点（白名单首个根目录），避免客户端硬编码 /root。
  String? _dir;

  ComposeDirKey get _key => (serverId: widget.serverId, dir: _dir);

  void _reload() => ref.invalidate(composeListingProvider(_key));

  void _enter(String path) => setState(() => _dir = path);

  void _openFile(ComposeFileItem file) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ComposeFilePage(
          serverId: widget.serverId,
          path: file.path,
          name: file.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(composeListingProvider(_key));
    final listing = state.valueOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compose 编排'),
        actions: [
          IconButton(
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '重新列目录',
          ),
        ],
      ),
      body: Column(
        children: [
          // 面包屑放在 AsyncStateView 外面：子目录为空时用户仍然要能退回上一层，
          // 如果连导航一起被空态替换掉，就只剩「返回上一页」这一条出路。
          if (listing != null)
            _BrowserHeader(
              listing: listing,
              onEnter: _enter,
              onPickRoot: _enter,
            ),
          Expanded(
            child: AsyncStateView<ComposeListing>(
              value: state,
              isEmpty: (data) => data.isEmpty,
              loadingHint: '正在通过 SFTP 列目录…',
              onRetry: _reload,
              emptyHint: '这个目录（${listing?.dir ?? '白名单根目录'}）下没有 compose 文件，'
                  '也没有可下钻的子目录。\n\n'
                  '后端只在白名单目录里查找（当前白名单：'
                  '${listing?.roots.join('、') ?? '由服务端决定'}），'
                  '常见位置是 /opt/<应用>/docker-compose.yml 或 /root/docker-compose.yml。'
                  '\n\n如果文件确实在别处，需要先在面板设置里调整 compose.roots 白名单。',
              builder: (data) {
                final entries = <_Entry>[
                  for (final name in data.dirs)
                    _Entry.dir(name: name, path: _joinPath(data.dir, name)),
                  for (final file in data.files) _Entry.file(file),
                ];
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 32),
                    itemCount: entries.length + (data.skipped > 0 ? 1 : 0),
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == entries.length) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            '本目录另有 ${data.skipped} 个条目不是 compose 文件，未显示',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        );
                      }
                      final entry = entries[index];
                      if (entry.isDir) {
                        return ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(entry.name),
                          subtitle: const Text('目录 · 点开继续下钻'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _enter(entry.path),
                        );
                      }
                      final file = entry.file!;
                      return ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(file.name),
                        subtitle: Text(
                          '${formatComposeSize(file.size)} · '
                          '${formatComposeTime(file.modTime)}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openFile(file),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _joinPath(String dir, String name) {
    if (dir.isEmpty) return name;
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }
}

class _Entry {
  const _Entry.dir({required this.name, required this.path}) : file = null;
  const _Entry.file(this.file)
      : name = '',
        path = '';

  final String name;
  final String path;
  final ComposeFileItem? file;

  bool get isDir => file == null;
}

/// 面包屑 + 白名单根目录快捷入口。
class _BrowserHeader extends StatelessWidget {
  const _BrowserHeader({
    required this.listing,
    required this.onEnter,
    required this.onPickRoot,
  });

  final ComposeListing listing;
  final ValueChanged<String> onEnter;
  final ValueChanged<String> onPickRoot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = _crumbPaths(listing.dir, listing.roots);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    const Icon(Icons.chevron_right, size: 16),
                  TextButton(
                    style: TextButton.styleFrom(
                      // 最后一段是当前目录，不可点（点了也是原地刷新）。
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: i == crumbs.length - 1
                        ? null
                        : () => onEnter(crumbs[i].$2),
                    child: Text(
                      crumbs[i].$1,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: i == crumbs.length - 1
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (listing.roots.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final root in listing.roots)
                    ActionChip(
                      label: Text(
                        root,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onPickRoot(root),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '只在本机白名单目录内查找 compose 文件；'
              '文件内容与动作都通过 SFTP/SSH 直达被管机。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把绝对路径拆成「可点回去」的层级，并以匹配到的白名单根目录为起点。
  ///
  /// 从 `/` 起逐段拆会得到 `/root/opt/app` 这样的四段面包屑，而第一段 `root`
  /// 与白名单语义重复；先用白名单做最长前缀匹配，再从根目录之后拆。
  static List<(String, String)> _crumbPaths(String dir, List<String> roots) {
    if (dir.isEmpty) return const [('/', '')];

    // 最长前缀匹配：/root 与 /root/app 都在白名单时取更具体的那个。
    var base = '';
    for (final root in roots) {
      final normalized =
          root.endsWith('/') ? root.substring(0, root.length - 1) : root;
      if (dir == normalized || dir.startsWith('$normalized/')) {
        if (normalized.length > base.length) base = normalized;
      }
    }

    final segments = dir
        .substring(base.length)
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);

    final out = <(String, String)>[];
    // 第一节永远是白名单根（未命中白名单时就是 `/`），保证用户总能回到顶层。
    out.add((base.isEmpty ? '/' : base, base));
    var acc = base;
    for (final segment in segments) {
      acc = '$acc/$segment';
      out.add((segment, acc));
    }
    return out;
  }
}
