/// 远端 POSIX 路径的拼装与拆分。
///
/// 后端 `file.ValidatePath` 要求「绝对路径，且 `path.Clean` 之后不变」——
/// `/a//b`、`/a/./b`、`/a/../b` 一律 400。所以前端拼路径必须自己保证规范形态，
/// 不能写成 `'$dir/$name'`（目录是 `/` 时会拼出 `//x`，目录带尾斜杠时同理）。
String joinRemotePath(String dir, String name) {
  final clean = dir.trim();
  if (clean.isEmpty || clean == '/') return '/$name';
  final noTrailing = clean.endsWith('/')
      ? clean.substring(0, clean.length - 1)
      : clean;
  return '$noTrailing/$name';
}

/// 取父目录（`/etc/nginx/x.conf` → `/etc/nginx`，根目录仍是 `/`）。
String parentOf(String path) {
  if (path.isEmpty || path == '/') return '/';
  final trimmed = path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final idx = trimmed.lastIndexOf('/');
  return idx <= 0 ? '/' : trimmed.substring(0, idx);
}

/// 取文件名（`/etc/nginx/x.conf` → `x.conf`）。
String baseNameOf(String path) {
  if (path.isEmpty) return '';
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final idx = trimmed.lastIndexOf('/');
  return idx < 0 ? trimmed : trimmed.substring(idx + 1);
}

/// 在 [taken] 里挑一个不冲突的名字：`a.conf` → `a (1).conf` → `a (2).conf`。
///
/// 用于「上传撞名但用户不想覆盖」与「另存为副本」两个场景。
String freeName(String name, Set<String> taken) {
  if (!taken.contains(name)) return name;
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 1; i < 1000; i++) {
    final candidate = '$base ($i)$ext';
    if (!taken.contains(candidate)) return candidate;
  }
  return '$base-${DateTime.now().millisecondsSinceEpoch}$ext';
}
