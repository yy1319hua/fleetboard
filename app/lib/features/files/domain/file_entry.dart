/// 远端文件/目录条目（对齐后端 `file.Entry`）。
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.dir,
    required this.size,
    required this.mode,
    required this.uid,
    required this.gid,
    required this.modTime,
  });

  final String name;
  final String path;
  final bool dir;
  final int size;

  /// 形如 `-rw-r--r--`，已由后端格式化，前端不再解析权限位。
  final String mode;
  final int uid;
  final int gid;
  final DateTime modTime;

  factory FileEntry.fromJson(Map<String, dynamic> json) {
    final rawTs = json['mod_time'];
    return FileEntry(
      name: (json['name'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      dir: json['dir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      mode: (json['mode'] as String?) ?? '',
      uid: (json['uid'] as num?)?.toInt() ?? 0,
      gid: (json['gid'] as num?)?.toInt() ?? 0,
      modTime: rawTs is String
          ? (DateTime.tryParse(rawTs)?.toLocal() ?? DateTime.now())
          : DateTime.now(),
    );
  }

  /// 人类可读大小（列表右列展示，固定宽度用等宽数字）。
  String get sizeLabel {
    if (dir) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = size.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return i == 0 ? '${v.toInt()}${units[i]}' : '${v.toStringAsFixed(1)}${units[i]}';
  }
}

/// 目录列表结果（后端分页参数原样带回，便于「加载更多」）。
class FileListing {
  const FileListing({
    required this.entries,
    required this.total,
    required this.offset,
    required this.limit,
  });

  final List<FileEntry> entries;
  final int total;
  final int offset;
  final int limit;

  bool get hasMore => offset + entries.length < total;

  /// 追加下一页（「加载更多」）。
  ///
  /// offset 保持本页的值（通常是 0）：[hasMore] 的判定必须是
  /// 「已拿到的条数 < 总数」。若把第二页的 `offset=200` 拿来当基准，
  /// 就会变成 200 + 400 < 500 → 误判成没有更多。
  FileListing appended(FileListing next) => FileListing(
        entries: <FileEntry>[...entries, ...next.entries],
        total: next.total,
        offset: offset,
        limit: next.limit,
      );
}

/// 远端文本内容 + 服务端视角的字节数。
///
/// [size] 是服务端实际读到的字节数（Go 侧 `len(content)`）。在线编辑保存前
/// 用它和当前文件的实际大小比对，就能发现「我编辑的这段时间里别人改过这个文件」。
class RemoteText {
  const RemoteText({required this.content, required this.size});

  final String content;
  final int size;
}
