/// 操作审计条目（对齐 `internal/model.OperationLog`）。
///
/// 字段真相（不是产品文档里写的「方法 / 路径 / 状态码」）：
///  - `action`：中间件写入的是 `"<METHOD> <路由模板>"`，例如
///    `"POST /api/servers/:id/compose/actions"`。所以"方法"和"路由"要从这里拆，
///    后端**没有**单独字段。
///  - `detail`：写入的是 `c.Request.URL.Path`，即**真实路径**（带具体 id），
///    排查时比路由模板有用得多。
///  - `result`：只有 `"ok"` / `"fail"` 两个值（按 HTTP 状态码 >= 400 判定）。
///    后端不记录状态码数字，所以界面上不能显示 "200/502" 这类假信息。
///  - `server_id`：中间件统一写 null；只有 packages/logs/upgrade 等少数 handler
///    显式补了服务器 ID。所以这一列大量是「未记录」，如实显示。
library;

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.userId,
    required this.serverId,
    required this.action,
    required this.detail,
    required this.result,
    required this.createdAt,
  });

  final int id;
  final int userId;
  final int? serverId;
  final String action;
  final String detail;
  final String result;
  final DateTime? createdAt;

  /// `"POST /api/..."` → `POST`。格式不符时返回 `—`。
  String get method {
    final index = action.indexOf(' ');
    if (index <= 0) return '—';
    return action.substring(0, index);
  }

  /// `"POST /api/..."` → `/api/...`（路由模板）。
  String get route {
    final index = action.indexOf(' ');
    if (index <= 0) return action;
    return action.substring(index + 1);
  }

  bool get ok => result.toLowerCase() == 'ok';

  String get resultLabel => switch (result.toLowerCase()) {
        'ok' => '成功',
        'fail' => '失败',
        _ => result.isEmpty ? '未知' : result,
      };

  /// 是不是写操作（用于「只看写操作」这类筛选，以及 UI 上的强调）。
  bool get isMutating =>
      method == 'POST' || method == 'PUT' || method == 'PATCH' || method == 'DELETE';

  factory AuditEntry.fromJson(Map<String, dynamic> json) {
    final rawTime = json['created_at'];
    return AuditEntry(
      id: (json['id'] as num?)?.toInt() ?? 0,
      userId: (json['user_id'] as num?)?.toInt() ?? 0,
      serverId: (json['server_id'] as num?)?.toInt(),
      action: (json['action'] as String?) ?? '',
      detail: (json['detail'] as String?) ?? '',
      result: (json['result'] as String?) ?? '',
      createdAt: rawTime is String ? DateTime.tryParse(rawTime)?.toLocal() : null,
    );
  }
}

/// `MM-dd HH:mm:ss`（审计按天看，年份对排查没意义，省略以留出路径宽度）。
String formatAuditTime(DateTime? time) {
  if (time == null) return '时间未知';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// 完整时间（详情页用，带年份与本地时区标记）。
String formatAuditTimeFull(DateTime? time) {
  if (time == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
