import 'package:dio/dio.dart';

import '../../../core/errors/api_exception.dart';

/// 取出后端业务码（DioException 里的信封码优先，其次 HTTP 状态）。
int? apiCodeOf(Object error) {
  if (error is DioException) {
    final inner = error.error;
    if (inner is ApiException && inner.code != null) return inner.code;
    return error.response?.statusCode;
  }
  if (error is ApiException) return error.code;
  return null;
}

/// 文件域错误文案：在通用解包之上补「权限 / 不存在 / 目录」这些文件语义。
///
/// 为什么不能直接用 [describeApiError]：后端把 SFTP 的失败统一包成
/// 502「读取目录失败: permission denied」。直接把这句话甩给用户，
/// 用户只会以为面板坏了；实际上这是「这个 SSH 账户读不了这个目录」，
/// 是有明确下一步（返回上级 / 换账户）的可恢复状态。
String describeFilesError(Object error, {String? path}) {
  final code = apiCodeOf(error);
  final raw = describeApiError(error);
  final lower = raw.toLowerCase();
  final target = (path == null || path.isEmpty) ? '该路径' : path;

  if (lower.contains('permission denied') || code == 403) {
    return '没有权限访问 $target。当前 SSH 账户在此目录没有读权限，'
        '可以返回上一级，或换用有权限的账户。';
  }
  if (lower.contains('no such file') ||
      lower.contains('does not exist') ||
      lower.contains('not exist') ||
      code == 404) {
    return '$target 不存在，可能已被移动或删除。';
  }
  if (lower.contains('is a directory')) {
    return '$target 是目录，不能按文件打开。';
  }
  if (lower.contains('too many open files')) {
    return '服务器打开的文件过多，稍后重试。';
  }
  if (lower.contains('no space left')) {
    return '服务器磁盘已满，无法写入 $target。';
  }
  return raw;
}

/// 目录为空时的文案（根目录与普通目录分开说）。
String emptyDirHint(String path) {
  if (path == '/' || path.isEmpty) {
    return '根目录 / 下没有任何文件。\n可以用右上角的上传按钮往这里放文件。';
  }
  return '这个目录是空的。\n可以用右上角的上传按钮往这里放文件。';
}
