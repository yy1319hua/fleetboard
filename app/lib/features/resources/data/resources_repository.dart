import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/docker_resource.dart';

/// 资源域仓储：镜像 / 网络 / 卷。
///
/// 契约（`internal/api/docker_handlers.go` + `router.go`）：
///  - `GET    /api/servers/:id/images`            → `[{id, repository, tag, size, created_since}]`
///  - `POST   /api/servers/:id/images/pull`       → `{image, output}`（**同步**，无 202/jobId）
///  - `DELETE /api/servers/:id/images/:imageId`   → `{deleted, output}`（镜像不存在视为成功）
///  - `GET    /api/servers/:id/networks`          → `[{id, name, driver, scope}]`
///  - `GET    /api/servers/:id/volumes`           → `[{name, driver, mountpoint}]`
///  - `DELETE /api/servers/:id/volumes/:name`     → `{deleted, output}`（被容器占用时 409）
///  - `GET    /api/servers/:id/docker/df`         → `[{type, total_count, active, size, reclaimable, prune_target, prune_coverage}]`
///  - `GET    /api/servers/:id/docker/unused-volumes` → `{volumes:[{name, compose_project}], count, total_count, in_use_count, reclaimable}`
///  - `POST   /api/servers/:id/docker/prune`      → `{results: [{target, output, reclaimed, deleted_items, deleted_count, nothing_deleted, error}]}`
///
/// 网络**只有 GET**：`router.go` 里没有 `/networks` 的写路由，所以 App 端不做
/// 创建/删除（不做灰按钮，页面上直接写清「去 Web 端」）。
///
/// `pull` 走 `streamDio`：`docker pull` 几分钟很常见，JSON 档 20s 的 receiveTimeout
/// 会在拉取**正在进行**时报超时，用户重试一次就是重复拉取。
class ResourcesRepository {
  ResourcesRepository(this._json, this._stream);

  final Dio _json;
  final Dio _stream;

  Future<List<DockerImage>> listImages(int serverId) async {
    final resp = await _json.get<dynamic>('/api/servers/$serverId/images');
    return unwrapList<DockerImage>(resp.data, DockerImage.fromJson);
  }

  Future<List<DockerNetwork>> listNetworks(int serverId) async {
    final resp = await _json.get<dynamic>('/api/servers/$serverId/networks');
    return unwrapList<DockerNetwork>(resp.data, DockerNetwork.fromJson);
  }

  Future<List<DockerVolume>> listVolumes(int serverId) async {
    final resp = await _json.get<dynamic>('/api/servers/$serverId/volumes');
    return unwrapList<DockerVolume>(resp.data, DockerVolume.fromJson);
  }

  /// 拉取镜像，返回 docker 的合并输出（进度行都在里面）。
  Future<String> pullImage(
    int serverId,
    String reference, {
    CancelToken? cancelToken,
  }) async {
    final resp = await _stream.post<dynamic>(
      '/api/servers/$serverId/images/pull',
      data: <String, dynamic>{'image': reference},
      cancelToken: cancelToken,
    );
    final data = unwrap<Map<String, dynamic>>(resp.data, (json) => json);
    return (data['output'] as String?) ?? '';
  }

  /// 删除镜像。必须用镜像 **ID**（见 [DockerImage.id] 注释）。
  Future<String> removeImage(int serverId, String imageId) async {
    final resp = await _json.delete<dynamic>(
      // ID 可能带 `sha256:` 前缀，作为路径段必须整体编码（`:` 是保留字符）。
      '/api/servers/$serverId/images/${Uri.encodeComponent(imageId)}',
    );
    final data = unwrap<Map<String, dynamic>>(resp.data, (json) => json);
    return (data['output'] as String?) ?? '';
  }

  /// 删除数据卷（卷内数据一并删除）。
  ///
  /// 卷仍被容器引用时后端返回 409 且消息里带容器名，[describeApiError]
  /// 会原样透出，UI 直接展示即可——不要吞掉这句换成人话，用户需要知道是哪个容器。
  Future<String> removeVolume(int serverId, String name) async {
    final resp = await _json.delete<dynamic>(
      '/api/servers/$serverId/volumes/${Uri.encodeComponent(name)}',
    );
    final data = unwrap<Map<String, dynamic>>(resp.data, (json) => json);
    return (data['output'] as String?) ?? '';
  }

  /// Docker 空间占用（`docker system df`）。
  Future<List<DockerDiskUsage>> diskUsage(int serverId) async {
    final resp = await _json.get<dynamic>('/api/servers/$serverId/docker/df');
    return unwrapList<DockerDiskUsage>(resp.data, DockerDiskUsage.fromJson);
  }

  /// 未使用卷预览：执行清理**之前**把将被删除的卷名列出来。
  ///
  /// 独立端点而不是前端拿 [volumesProvider] 自己过滤：卷是否「未被使用」
  /// 只有 docker 知道（`dangling=true` 含已停止容器的引用判断），
  /// 客户端筛会漏也会误。清单与后端 `docker volume prune -a -f` 同口径。
  Future<DockerVolumePreview> unusedVolumes(int serverId) async {
    final resp =
        await _json.get<dynamic>('/api/servers/$serverId/docker/unused-volumes');
    return unwrap<DockerVolumePreview>(resp.data, DockerVolumePreview.fromJson);
  }

  /// 回收空间。targets 必须显式给出（后端不接受空数组）。
  Future<List<DockerPruneOutcome>> prune(
    int serverId, {
    required List<String> targets,
  }) async {
    final resp = await _json.post<dynamic>(
      '/api/servers/$serverId/docker/prune',
      data: <String, dynamic>{'targets': targets},
    );
    final data = unwrap<Map<String, dynamic>>(resp.data, (json) => json);
    final raw = (data['results'] as List<dynamic>?) ?? const <dynamic>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DockerPruneOutcome.fromJson)
        .toList(growable: false);
  }
}

final resourcesRepositoryProvider = Provider<ResourcesRepository>(
  (ref) => ResourcesRepository(
    ref.watch(jsonDioProvider),
    ref.watch(streamDioProvider),
  ),
);

/// 三个列表各自的 provider：按 Tab 独立加载、独立重试，互不牵连。
///
/// 用 FutureProvider 而不是 StateNotifier：这三个列表没有轮询、没有本地变更，
/// 只需要「拉一次 + 手动 invalidate」，多写一个 Notifier 只会多一份状态同步负担。
final imagesProvider =
    FutureProvider.autoDispose.family<List<DockerImage>, int>(
  (ref, serverId) =>
      ref.watch(resourcesRepositoryProvider).listImages(serverId),
);

final networksProvider =
    FutureProvider.autoDispose.family<List<DockerNetwork>, int>(
  (ref, serverId) =>
      ref.watch(resourcesRepositoryProvider).listNetworks(serverId),
);

final volumesProvider =
    FutureProvider.autoDispose.family<List<DockerVolume>, int>(
  (ref, serverId) =>
      ref.watch(resourcesRepositoryProvider).listVolumes(serverId),
);

/// 空间占用：清理入口打开时拉一次，清理完成后再失效重取。
final diskUsageProvider =
    FutureProvider.autoDispose.family<List<DockerDiskUsage>, int>(
  (ref, serverId) =>
      ref.watch(resourcesRepositoryProvider).diskUsage(serverId),
);

/// 未使用卷预览：只在清理弹层勾选「未使用卷」时被 watch，
/// autoDispose 保证没人看就不发这次 SSH；弹层关闭即释放。
final unusedVolumesProvider =
    FutureProvider.autoDispose.family<DockerVolumePreview, int>(
  (ref, serverId) =>
      ref.watch(resourcesRepositoryProvider).unusedVolumes(serverId),
);
