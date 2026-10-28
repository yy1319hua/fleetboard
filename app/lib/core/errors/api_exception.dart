/// 统一错误信封解包骨架（M9.1 仅落地骨架；unwrap 在 M9.2 的 http 层实现）。
///
/// 后端契约：所有响应统一信封 `{ code, msg, data }`（见 M9 方案 §4.1）。
///  - 成功：code == 0，data 为业务负载。
///  - 失败：code != 0 或 HTTP 非 2xx，统一抛 [ApiException]。
///  - 上层只见到 T 或异常，不直接解析信封。
///
/// M9.2 横切（§2.3）：
///  1) dio onResponse 统一 unwrap<T> 解析信封，非成功码抛 [ApiException]；
///  2) 错误码 -> 集中中文案 Map<int,String>，未命中回退 serverMsg。
class ApiException implements Exception {
  const ApiException({
    this.code,
    required this.message,
    this.data,
  });

  final int? code;
  final String message;
  final dynamic data;

  @override
  String toString() => 'ApiException(code: $code, message: $message)';
}

/// M9.2 实现示意（不在此步实现，避免引用未定义符号）：
/// ```dart
/// T unwrap<T>(Map<String, dynamic> envelope) {
///   final code = envelope['code'] as int? ?? -1;
///   if (code != 0) {
///     throw ApiException(
///       code: code,
///       message: envelope['msg'] as String? ?? '未知错误',
///     );
///   }
///   return envelope['data'] as T;
/// }
/// ```
