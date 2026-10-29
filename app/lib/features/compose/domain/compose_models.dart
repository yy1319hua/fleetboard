/// Compose 编排的传输模型（对齐 `internal/api/compose_handlers.go` 的真实响应）。
///
/// 一个必须先说清的契约事实：`GET /api/servers/{id}/compose` 返回的是**单个目录的
/// 浏览结果**（`{roots, dir, dirs, files, skipped}`），不是「这台机器上所有 compose
/// 文件」，也不是「每个文件的服务列表」。后端从白名单首个根目录（默认 /root）起，
/// 只列一层，下钻靠 `?dir=`。因此 UI 必须是「面包屑 + 下钻」而不是一次性平铺——
/// 想平铺就得递归扫描整个白名单，等于每次进页面都开 N 次 SFTP 会话。
///
/// 另外后端列表**不含服务名与运行状态**（`compose.FileItem` 只有 name/path/size/
/// mod_time）。服务名需要读文件内容解析 YAML 才有，所以它在文件详情页出现，
/// 而「服务是否在运行」后端没有对应字段，页面不去猜（见 ComposeFilePage 注释）。
library;

/// 一个 compose 文件条目（对齐 `compose.FileItem`）。
class ComposeFileItem {
  const ComposeFileItem({
    required this.name,
    required this.path,
    required this.size,
    required this.modTime,
  });

  final String name;
  final String path;
  final int size;

  /// 后端为 Go `time.Time`，RFC3339 字符串；解析失败时保留 null 而不是编一个时间。
  final DateTime? modTime;

  factory ComposeFileItem.fromJson(Map<String, dynamic> json) {
    final rawTime = json['mod_time'];
    return ComposeFileItem(
      name: (json['name'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modTime: rawTime is String ? DateTime.tryParse(rawTime)?.toLocal() : null,
    );
  }
}

/// 一次目录浏览的结果。
class ComposeListing {
  const ComposeListing({
    required this.roots,
    required this.dir,
    required this.dirs,
    required this.files,
    required this.skipped,
  });

  /// 服务端当前生效的白名单根目录（设置里可改，接口每请求重读，所以由后端下发，
  /// 客户端不硬编码 `/root`）。
  final List<String> roots;

  /// 本次列出的绝对目录。
  final String dir;

  /// 可下钻的子目录名（不含路径）。
  final List<String> dirs;

  final List<ComposeFileItem> files;

  /// 本目录内被判定为「不是 compose 文件」而跳过的条目数，用于给用户一句解释。
  final int skipped;

  bool get isEmpty => dirs.isEmpty && files.isEmpty;

  factory ComposeListing.fromJson(Map<String, dynamic> json) {
    return ComposeListing(
      roots: _stringList(json['roots']),
      dir: (json['dir'] as String?) ?? '',
      dirs: _stringList(json['dirs']),
      files: _mapList(json['files'])
          .map(ComposeFileItem.fromJson)
          .toList(growable: false),
      skipped: (json['skipped'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 单个 compose 文件的内容（对齐 `GET .../compose/content` 的 data）。
class ComposeContent {
  const ComposeContent({
    required this.path,
    required this.content,
    required this.size,
  });

  final String path;
  final String content;

  /// 服务端返回的字节数（UTF-8），可能小于 content.length（中文注释）。
  final int size;

  factory ComposeContent.fromJson(Map<String, dynamic> json) => ComposeContent(
        path: (json['path'] as String?) ?? '',
        content: (json['content'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

/// 一次 compose 动作的执行结果（对齐 `POST .../compose/actions` 的 data）。
///
/// 后端是**同步**执行并把合并输出直接返回（200），没有 202 + jobId，
/// 所以这里不存在「接 job 轮询」这回事：动作期间界面靠本地 busy 态撑住。
class ComposeActionResult {
  const ComposeActionResult({
    required this.path,
    required this.action,
    required this.output,
  });

  final String path;
  final String action;

  /// `docker compose ...` 的 stdout+stderr 合并输出；失败时后端会带上部分输出，
  /// 所以失败弹层也要能显示这段文本，而不是只给一句「执行失败」。
  final String output;

  factory ComposeActionResult.fromJson(Map<String, dynamic> json) =>
      ComposeActionResult(
        path: (json['path'] as String?) ?? '',
        action: (json['action'] as String?) ?? '',
        output: (json['output'] as String?) ?? '',
      );
}

/// 人类可读的文件大小。运维看 compose 文件只关心量级，保留一位小数即可。
String formatComposeSize(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

/// `MM-dd HH:mm`（跨年的文件补上日期里的年份信息由列表排序承担，不额外占宽度）。
String formatComposeTime(DateTime? time) {
  if (time == null) return '时间未知';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const <String>[];
  return raw.whereType<String>().toList(growable: false);
}

List<Map<String, dynamic>> _mapList(dynamic raw) {
  if (raw is! List) return const <Map<String, dynamic>>[];
  return raw.whereType<Map<String, dynamic>>().toList(growable: false);
}
