/// 只读资源域（镜像 / 网络 / 卷）的传输模型。
///
/// 全部对齐 `internal/docker/service.go` 里手写的 JSON 结构（不是 `docker ... --json`
/// 的原始字段名）：后端把 `ID/Repository/Tag` 转成了 `id/repository/tag` 这类小写键，
/// 客户端按小写读；读大写是拿不到值的静默失败，所以这里显式记录一次。
library;

/// 本地镜像（对齐 `docker.Image`）。
class DockerImage {
  const DockerImage({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
    required this.createdSince,
  });

  /// 完整镜像 ID（可能是 `sha256:...`）。删除接口只接受 ID，不接受 `repo:tag`：
  /// 后端 `ValidateImageID` 的字符白名单里没有 `/`，用名字会 400。
  final String id;
  final String repository;
  final String tag;

  /// 后端直接透传 `docker images` 的人类可读大小（如 `142MB`），不换算成字节。
  final String size;
  final String createdSince;

  bool get isDangling => repository.isEmpty || repository == '<none>';

  /// 展示用的引用名。
  String get reference {
    if (isDangling) {
      final short = id.length > 19 ? id.substring(id.length - 12) : id;
      return '无仓库名镜像（$short）';
    }
    if (tag.isEmpty || tag == '<none>') return repository;
    return '$repository:$tag';
  }

  /// 能否删除：没有 ID 就没法调 DELETE，UI 要给出原因而不是给个点不动的按钮。
  bool get canDelete => id.trim().isNotEmpty;

  factory DockerImage.fromJson(Map<String, dynamic> json) => DockerImage(
        id: (json['id'] as String?) ?? '',
        repository: (json['repository'] as String?) ?? '',
        tag: (json['tag'] as String?) ?? '',
        size: (json['size'] as String?) ?? '',
        createdSince: (json['created_since'] as String?) ?? '',
      );
}

/// Docker 网络（对齐 `docker.Network`）。
class DockerNetwork {
  const DockerNetwork({
    required this.id,
    required this.name,
    required this.driver,
    required this.scope,
  });

  final String id;
  final String name;
  final String driver;
  final String scope;

  factory DockerNetwork.fromJson(Map<String, dynamic> json) => DockerNetwork(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        driver: (json['driver'] as String?) ?? '',
        scope: (json['scope'] as String?) ?? '',
      );
}

/// Docker 数据卷（对齐 `docker.Volume`）。
class DockerVolume {
  const DockerVolume({
    required this.name,
    required this.driver,
    required this.mountpoint,
    this.composeProject = '',
  });

  final String name;
  final String driver;
  final String mountpoint;

  /// 所属 compose 项目（`com.docker.compose.project` 标签）。仅未使用卷预览接口返回；
  /// 空串表示非 compose 卷或该接口未提供。
  final String composeProject;

  factory DockerVolume.fromJson(Map<String, dynamic> json) => DockerVolume(
        name: (json['name'] as String?) ?? '',
        driver: (json['driver'] as String?) ?? '',
        mountpoint: (json['mountpoint'] as String?) ?? '',
        composeProject: (json['compose_project'] as String?) ?? '',
      );
}

/// Docker 空间占用的一行（对齐 `docker.DiskUsage`，来自 `docker system df`）。
class DockerDiskUsage {
  const DockerDiskUsage({
    required this.type,
    required this.totalCount,
    required this.active,
    required this.size,
    required this.reclaimable,
  });

  /// 类型名由 docker 给出（Images / Containers / Local Volumes / Build Cache）。
  final String type;
  final String totalCount;
  final String active;

  /// 人类可读容量串（如 `1.2GB`），后端不换算字节。
  final String size;

  /// 形如 `800MB (66%)`；后端原样透传，不做拆分。
  final String reclaimable;

  /// 去掉百分比后的可回收容量，用于摘要展示。
  String get reclaimableSize {
    final idx = reclaimable.indexOf(' (');
    return idx < 0 ? reclaimable : reclaimable.substring(0, idx);
  }

  factory DockerDiskUsage.fromJson(Map<String, dynamic> json) => DockerDiskUsage(
        type: (json['type'] as String?) ?? '',
        totalCount: (json['total_count'] as String?) ?? '',
        active: (json['active'] as String?) ?? '',
        size: (json['size'] as String?) ?? '',
        reclaimable: (json['reclaimable'] as String?) ?? '',
      );
}

/// 单个清理目标的回收结果（对齐 `docker.PruneResult`）。
class DockerPruneOutcome {
  const DockerPruneOutcome({
    required this.target,
    required this.output,
    required this.reclaimed,
    this.deletedItems = const <String>[],
    this.deletedCount,
    this.nothingDeleted,
    this.error = '',
  });

  /// images / volumes / build_cache。
  final String target;
  final String output;

  /// 形如 `1.234GB`；docker 未输出该行时为空串。
  final String reclaimed;

  /// 实际删除的条目：卷名 / 镜像引用 / 缓存 ID。
  final List<String> deletedItems;

  /// 后端报告的删除条数。**null = 后端没报（旧版本）**，不是 0。
  final int? deletedCount;

  /// 后端明确表示「本次没有可删项」。null = 未报告。
  final bool? nothingDeleted;

  /// 单项失败原因；空串表示该项成功。由后端逐项返回，原样展示，不改写。
  final String error;

  bool get failed => error.trim().isNotEmpty;

  /// 后端是否报告了「删了什么」。
  bool get reported => deletedCount != null || deletedItems.isNotEmpty;

  int get actualDeletedCount => deletedCount ?? deletedItems.length;

  /// 执行成功但一项都没删。
  bool get deletedNothing =>
      !failed && (nothingDeleted ?? (reported && actualDeletedCount == 0));

  /// 目标的中文名，用于结果展示。
  String get label {
    switch (target) {
      case 'images':
        return '悬空镜像';
      case 'volumes':
        return '未使用卷';
      case 'build_cache':
        return '构建缓存';
      default:
        return target;
    }
  }

  factory DockerPruneOutcome.fromJson(Map<String, dynamic> json) =>
      DockerPruneOutcome(
        target: (json['target'] as String?) ?? '',
        output: (json['output'] as String?) ?? '',
        reclaimed: (json['reclaimed'] as String?) ?? '',
        deletedItems: (json['deleted_items'] as List<dynamic>?)
                ?.whereType<String>()
                .toList(growable: false) ??
            const <String>[],
        deletedCount: _asInt(json['deleted_count']),
        nothingDeleted: json['nothing_deleted'] as bool?,
        error: (json['error'] as String?) ?? '',
      );
}

/// 未使用卷预览（`GET /api/servers/:id/docker/unused-volumes`）。
///
/// 为什么要这个接口：`docker volume prune` 的输出只有一句
/// 「Total reclaimed space: 0B」，执行前用户完全不知道会删哪些卷，
/// 于是出现「显示已清理、卷还在」的观感。
class DockerVolumePreview {
  const DockerVolumePreview({
    required this.volumes,
    required this.count,
    required this.totalCount,
    required this.inUseCount,
    required this.reclaimable,
  });

  /// 将被删除的卷（无任何容器引用，**含命名卷**）。
  final List<DockerVolume> volumes;

  final int count;

  /// 该机器卷总数（含被引用的），用于解释「为什么一个都删不掉」。
  final int totalCount;

  /// 仍被容器引用（含已停止容器）的卷数。
  final int inUseCount;

  /// 与 `docker system df` 的本地卷行同源。
  final String reclaimable;

  factory DockerVolumePreview.fromJson(Map<String, dynamic> json) {
    final raw = json['volumes'];
    final list = raw is List<dynamic>
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(DockerVolume.fromJson)
            .toList(growable: false)
        : const <DockerVolume>[];
    return DockerVolumePreview(
      volumes: list,
      count: _asInt(json['count']) ?? list.length,
      totalCount: _asInt(json['total_count']) ?? list.length,
      inUseCount: _asInt(json['in_use_count']) ?? 0,
      reclaimable: (json['reclaimable'] as String?) ?? '',
    );
  }
}

int? _asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

/// docker 的人类可读容量串 → 字节；无法识别返回 null（宁可不算，不编造）。
int? parseDockerSizeBytes(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final m =
      RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*([kKmMgGtTpP]?)B$').firstMatch(text);
  if (m == null) return null;
  final value = double.tryParse(m.group(1)!);
  if (value == null) return null;
  final exp = const {'': 0, 'K': 1, 'M': 2, 'G': 3, 'T': 4, 'P': 5}[
      m.group(2)!.toUpperCase()];
  if (exp == null) return null;
  return (value * _pow1024(exp)).round();
}

double _pow1024(int exp) {
  var v = 1.0;
  for (var i = 0; i < exp; i++) {
    v *= 1024;
  }
  return v;
}

/// 字节 → `85.94MB` / `1.2GB`（1024 进制，去尾零）。
String formatSizeBytes(int bytes) {
  if (bytes <= 0) return '0B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i += 1;
  }
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return '$text${units[i]}';
}

/// 卷名本地校验，规则与后端 `docker.ValidateVolumeName` 一致。
///
/// 后端的白名单是防命令注入的硬约束（卷名会拼进 `docker volume rm`），
/// 客户端镜像一份只是为了提前给出可读提示，不能放宽。
String? validateVolumeName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '卷名不能为空';
  if (name.length > 255) return '卷名过长（上限 255 个字符）';
  final pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.\-]{0,254}$');
  if (!pattern.hasMatch(name)) {
    return '卷名只能包含字母、数字和 _ - .，且必须以字母或数字开头';
  }
  return null;
}

/// 镜像引用本地校验，规则与后端 `docker.ValidateImageRef` 逐条对齐。
///
/// 为什么要在客户端先校验一遍：拉取镜像是个长达几十秒的操作，用户敲错一个字符
/// 却要等半分钟才看到「镜像名含非法字符」，体验极差；而后端的字符白名单是防命令
/// 注入的硬约束，客户端**不能放宽**（放宽了照样被 400，只是更晚）。
String? validateImageReference(String raw) {
  final ref = raw.trim();
  if (ref.isEmpty) return '请输入镜像名，例如 nginx:alpine';
  if (ref.length > 255) return '镜像名过长（上限 255 个字符）';
  final pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.\-/:@]*$');
  if (!pattern.hasMatch(ref)) {
    return '只能包含字母、数字和 _ - . / : @，且必须以字母或数字开头';
  }
  return null;
}
