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
  });

  final String name;
  final String driver;
  final String mountpoint;

  factory DockerVolume.fromJson(Map<String, dynamic> json) => DockerVolume(
        name: (json['name'] as String?) ?? '',
        driver: (json['driver'] as String?) ?? '',
        mountpoint: (json['mountpoint'] as String?) ?? '',
      );
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
