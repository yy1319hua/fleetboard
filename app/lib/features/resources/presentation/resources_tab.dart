import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_state_view.dart';
import '../data/resources_repository.dart';
import '../domain/docker_resource.dart';
import 'image_actions.dart';
import 'volume_actions.dart';

/// 服务器详情 · 资源域（镜像 / 网络 / 卷）。
///
/// 三个子 Tab 而不是三个页面：它们回答的是同一类问题——「这台机器上有什么
/// 可回收/占空间的东西」，来回切换比进出三个页面快得多。
///
/// 「能做什么」严格对齐后端能力，不做灰按钮：
///  - 镜像：列表 / 拉取 / 删除（`docker_handlers.go` 有 POST pull 与 DELETE image）；
///  - 卷：列表 / 删除（DELETE /volumes/:name，被容器占用时后端 409 并给出容器名）；
///  - 网络：**只有 GET**（`router.go` 里没有写路由），所以页面上用一句话
///    说明「去 Web 端或命令行创建/删除」，而不是摆一个禁用按钮让人反复点。
///  - 顶部「清理空间」：docker system df 展示可回收量，按目标清理（悬空镜像 /
///    未使用卷 / 构建缓存），只清没有容器引用的资源。
class ResourcesTab extends ConsumerStatefulWidget {
  const ResourcesTab({super.key, required this.serverId});

  final int serverId;

  @override
  ConsumerState<ResourcesTab> createState() => _ResourcesTabState();
}

class _ResourcesTabState extends ConsumerState<ResourcesTab>
    with SingleTickerProviderStateMixin {
  late final TabController _controller = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _controller,
          tabs: const [
            Tab(text: '镜像'),
            Tab(text: '网络'),
            Tab(text: '卷'),
          ],
        ),
        _CleanupEntry(serverId: widget.serverId),
        Expanded(
          child: TabBarView(
            controller: _controller,
            children: [
              _ImagesView(serverId: widget.serverId),
              _NetworksView(serverId: widget.serverId),
              _VolumesView(serverId: widget.serverId),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 镜像
// ---------------------------------------------------------------------------

class _ImagesView extends ConsumerWidget {
  const _ImagesView({required this.serverId});

  final int serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = imagesProvider(serverId);
    final state = ref.watch(provider);
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () async {
                  final pulled = await showPullImageDialog(
                    context,
                    serverId: serverId,
                  );
                  if (pulled) ref.invalidate(provider);
                },
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('拉取镜像'),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新列表',
                onPressed: () => ref.invalidate(provider),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncStateView<List<DockerImage>>(
            value: state,
            loadingHint: '正在通过 SSH 执行 docker images…',
            onRetry: () => ref.invalidate(provider),
            emptyHint: '这台机器上还没有镜像。点上方「拉取镜像」输入 repo:tag '
                '（例如 nginx:alpine）下载，拉取完成后会出现在这里。',
            builder: (images) => RefreshIndicator(
              onRefresh: () async => ref.invalidate(provider),
              child: ListView.separated(
                // 底部留白：详情页有底部导航，最后一行不该被盖住。
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: images.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final image = images[index];
                  return ListTile(
                    leading: Icon(
                      image.isDangling
                          ? Icons.link_off
                          : Icons.layers_outlined,
                      color: image.isDangling
                          ? theme.colorScheme.outline
                          : null,
                    ),
                    title: Text(
                      image.reference,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      [
                        if (image.size.isNotEmpty) image.size,
                        if (image.createdSince.isNotEmpty) image.createdSince,
                      ].join(' · '),
                    ),
                    // 长按删除：误触时手指抬不起来，比"点了弹出确认框"更能拦住手滑。
                    onLongPress: () async {
                      final deleted = await showDeleteImageSheet(
                        context,
                        serverId: serverId,
                        image: image,
                      );
                      if (deleted) ref.invalidate(provider);
                    },
                    onTap: () => _showImageDetail(context, image),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showImageDetail(BuildContext context, DockerImage image) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(image.reference,
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            _kv(sheetContext, '镜像 ID', image.id.isEmpty ? '—' : image.id),
            _kv(sheetContext, '大小', image.size.isEmpty ? '—' : image.size),
            _kv(sheetContext, '构建于',
                image.createdSince.isEmpty ? '—' : image.createdSince),
            const SizedBox(height: 12),
            Text(
              '删除镜像请长按列表中的这一行（删除不可撤销，且会影响用它的容器重启）。',
              style: Theme.of(sheetContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: image.id));
                  if (!sheetContext.mounted) return;
                  Navigator.of(sheetContext).pop();
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制镜像 ID'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String key, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(
              key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 网络（只读）
// ---------------------------------------------------------------------------

class _NetworksView extends ConsumerWidget {
  const _NetworksView({required this.serverId});

  final int serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = networksProvider(serverId);
    final state = ref.watch(provider);

    return Column(
      children: [
        const _ReadOnlyNotice(
          text: '网络只能查看：面板没有提供创建/删除网络的接口。'
              '需要自定义网络请在 Web 端或命令行执行 docker network create。',
        ),
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: '刷新列表',
            onPressed: () => ref.invalidate(provider),
            icon: const Icon(Icons.refresh),
          ),
        ),
        Expanded(
          child: AsyncStateView<List<DockerNetwork>>(
            value: state,
            loadingHint: '正在执行 docker network ls…',
            onRetry: () => ref.invalidate(provider),
            emptyHint: '没有查到任何网络。正常情况下至少有 bridge / host / none 三个，'
                '如果一个都没有，通常是 Docker 服务没起来——到「容器」页看一眼，'
                '或在机器上执行 systemctl status docker 排查。',
            builder: (networks) => RefreshIndicator(
              onRefresh: () async => ref.invalidate(provider),
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: networks.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final network = networks[index];
                  return ListTile(
                    leading: const Icon(Icons.hub_outlined),
                    title: Text(
                      network.name,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      '驱动 ${network.driver.isEmpty ? '—' : network.driver}'
                      ' · 范围 ${network.scope.isEmpty ? '—' : network.scope}'
                      '${network.id.isEmpty ? '' : ' · ${_shortId(network.id)}'}',
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 卷（可删除）
// ---------------------------------------------------------------------------

class _VolumesView extends ConsumerWidget {
  const _VolumesView({required this.serverId});

  final int serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = volumesProvider(serverId);
    final state = ref.watch(provider);
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '长按一行可删除该卷（卷内数据会一起删除）。'
                  '仍在被容器引用的卷会被拒绝，并提示是哪个容器。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新列表',
                onPressed: () => ref.invalidate(provider),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncStateView<List<DockerVolume>>(
            value: state,
            loadingHint: '正在执行 docker volume ls…',
            onRetry: () => ref.invalidate(provider),
            emptyHint: '没有数据卷。compose 里声明的具名卷会在第一次 docker compose up '
                '时自动创建，创建后会出现在这里。',
            builder: (volumes) => RefreshIndicator(
              onRefresh: () async => ref.invalidate(provider),
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: volumes.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final volume = volumes[index];
                  Future<void> askDelete() async {
                    final deleted = await showDeleteVolumeSheet(
                      context,
                      serverId: serverId,
                      volume: volume,
                    );
                    if (deleted) {
                      // 删卷同时改变 df 数字与未使用卷清单，一并失效。
                      ref.invalidate(provider);
                      ref.invalidate(diskUsageProvider(serverId));
                      ref.invalidate(unusedVolumesProvider(serverId));
                    }
                  }

                  return ListTile(
                    leading: const Icon(Icons.storage_outlined),
                    title: Text(
                      volume.name,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      '驱动 ${volume.driver.isEmpty ? '—' : volume.driver}'
                      '${volume.mountpoint.isEmpty ? '' : '\n${volume.mountpoint}'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: volume.mountpoint.isNotEmpty,
                    onLongPress: askDelete,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (volume.mountpoint.isNotEmpty)
                          IconButton(
                            tooltip: '复制挂载点',
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () async {
                              final messenger =
                                  ScaffoldMessenger.maybeOf(context);
                              await Clipboard.setData(
                                ClipboardData(text: volume.mountpoint),
                              );
                              messenger?.showSnackBar(
                                const SnackBar(content: Text('已复制挂载点路径')),
                              );
                            },
                          ),
                        IconButton(
                          tooltip: '删除卷',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: askDelete,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 顶部「清理空间」入口：先展示可回收量，点开才是勾选与长按确认。
///
/// 单独拉 `docker system df`：它比列表轻（一次 docker CLI 调用），
/// 但失败不影响镜像/卷列表本身，所以不使用列表的 AsyncValue。
class _CleanupEntry extends ConsumerWidget {
  const _CleanupEntry({required this.serverId});

  final int serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final usage = ref.watch(diskUsageProvider(serverId));
    final reclaimable = usage.maybeWhen(
      data: (rows) => _summarizeReclaimable(rows),
      orElse: () => '',
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          Icon(Icons.cleaning_services_outlined,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              reclaimable.isEmpty
                  ? 'Docker 占用与可回收空间'
                  // 「约」+ 限定语：这是 docker 的估算，且本页只清无引用资源，
                  // 不承诺「一定能腾出这么多」。
                  : 'Docker 可回收约 $reclaimable（只清无 tag 悬空镜像与无引用卷）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              final run = await showDockerCleanupSheet(
                context,
                serverId: serverId,
              );
              if (run == null || !context.mounted) return;
              // provider 失效已在弹层内部用 container 完成；
              // 这里只把结论再复述一次，避免用户关太快没读到结果。
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(
                  content: Text(
                    run.deletedSomething
                        ? '已删除 ${run.deletedTotal} 项 · '
                            '释放 ${formatSizeBytes(run.releasedBytes)}'
                        : '没有可清理的资源',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.auto_delete_outlined, size: 18),
            label: const Text('清理空间'),
          ),
        ],
      ),
    );
  }
}

/// 把各行「可回收」容量换算成字节求和，输出人类可读串。
///
/// docker 给的是 `1.2GB` / `800MB (66%)` 这类串，不做换算就没法合计；
/// 解析失败的项直接跳过（宁可少算，不编造数字）。
String _summarizeReclaimable(List<DockerDiskUsage> rows) {
  var total = 0;
  for (final row in rows) {
    total += parseDockerSizeBytes(row.reclaimableSize) ?? 0;
  }
  if (total <= 0) return '';
  return formatSizeBytes(total);
}


/// 只读提示条：明确「为什么这里没有写操作」，而不是把按钮置灰。
class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _shortId(String id) {
  final clean = id.replaceFirst('sha256:', '');
  return clean.length > 12 ? clean.substring(0, 12) : clean;
}
