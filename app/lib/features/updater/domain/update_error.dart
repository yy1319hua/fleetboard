/// 更新流程中的业务异常：文案可直接展示给用户（无需再包装）。
class UpdateError implements Exception {
  const UpdateError(this.message);

  final String message;

  @override
  String toString() => message;
}
