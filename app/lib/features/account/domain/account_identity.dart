/// 账户身份（`GET /api/me` 与 `POST /api/auth/change-username` 同构）。
///
/// 后端两处都只回 `{id, username}`：JWT claims 只有 uid，所以「我叫什么」
/// 只能从库里读，客户端不能靠登录响应里的快照一直用下去（改名后它就过期了）。
class AccountIdentity {
  const AccountIdentity({required this.id, required this.username});

  final int id;
  final String username;

  factory AccountIdentity.fromJson(Map<String, dynamic> json) {
    return AccountIdentity(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: (json['username'] as String?)?.trim() ?? '',
    );
  }
}

/// 用户名规则：与后端 `usernamePattern`（internal/api/auth_handlers.go）逐字一致。
///
/// 允许字母、数字、下划线、点、短横线，首字符必须是字母或数字，长度 3–32。
/// 前端先判一次**不是**为了替代服务端校验（服务端仍是唯一权威），而是为了把
/// 明显非法的输入就地拦下：这类错误用户看一眼就知道怎么改，发一趟网络再回一句
/// 400，只会让人以为是「服务器不允许我改名」。
final RegExp usernamePattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{2,31}$');

/// 就地校验用户名；返回 null 表示格式通过（不代表服务端一定接受）。
String? validateUsernameInput(String raw, {String? currentUsername}) {
  final value = raw.trim();
  if (value.isEmpty) return '请输入新用户名';
  if (!usernamePattern.hasMatch(value)) {
    return '需 3–32 位，以字母或数字开头，只能含字母、数字、下划线、点、短横线';
  }
  if (currentUsername != null && value == currentUsername) {
    return '新用户名与当前用户名相同';
  }
  return null;
}
