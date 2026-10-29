/// 统一错误信封与中文案解包（M9.2 落地）。
///
/// 后端契约：所有响应统一信封 `{ code, msg, data }`（见 internal/api/response.go）。
///  - 成功：HTTP 200，code == 0，data 为业务负载。
///  - 失败：HTTP 状态与 code 对齐（401/403/...），data 省略，msg 为文案。
///
/// 上层只见到 [ApiException] 或具体业务对象，不直接解析信封。
/// 中文案集中解析：401（含登录凭据错误）→ 凭据错误；无响应（网络）→ 网络错误；
/// 其余 → 服务器文案回落。
class ApiException implements Exception {
  const ApiException({
    this.code,
    required this.message,
    this.data,
  });

  final int? code;
  final String message;
  final dynamic data;

  bool get isUnauthorized => code == 401;

  @override
  String toString() => 'ApiException(code: $code, message: $message)';
}

/// 解包任意异常为面向用户的中文案。用于非登录类请求的兜底提示。
String resolveErrorMessage(Object error) {
  if (error is ApiException) return error.message;
  if (error is TypeError) return '数据解析异常，请升级客户端或联系管理员';
  // DioException 由调用方在更具体的位置处理；此处兜底。
  return '请求失败，请稍后重试';
}

/// 登录场景专用解包：401 = 凭据错误；网络 = 地址/网络问题；其余回落服务器文案。
String resolveLoginError(Object error) {
  if (error is ApiException) {
    if (error.code == 401) return '用户名或密码错误';
    if (error.message.isNotEmpty) return error.message;
    return '登录失败，请重试';
  }
  if (error is TypeError) return '服务器响应异常，请确认服务端版本';
  // M10.2：登录页已不再暴露地址输入，文案不再引导用户"检查服务器地址"。
  return '无法连接服务器，请检查网络或联系管理员';
}
