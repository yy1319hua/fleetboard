import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/audit_entry.dart';

/// 审计仓储。
///
/// 契约（`internal/api/audit_handlers.go` + `internal/db/audit.go`）：
///  - `GET /api/audit?limit=N`，**只有 limit 一个参数**；
///  - `limit` 默认 100，超过 500 被服务端夹到 500；
///  - 排序固定 `ORDER BY id DESC`（时间倒序）；
///  - 没有 offset、没有按用户/动作/结果的过滤参数。
///
/// 这决定了 UI 的两个事实：
///  1. 「加载更多」只能是**把 limit 加大重拉**（100 → 200 → … → 500），不是翻页；
///     到 500 就是硬上限，更早的记录必须去 Web 端或库里查。
///  2. 顶部筛选只能对**已加载的这一窗数据**做（客户端过滤）。如果把筛选说成
///     "服务端筛选"，用户会以为筛出的是全量结果，从而误判"为什么没有那条记录"。
class AuditRepository {
  AuditRepository(this._dio);

  final Dio _dio;

  /// 服务端硬上限（`db.ListAudit` 里 limit > 500 会被夹到 500）。
  static const int maxLimit = 500;

  /// 后端的默认值，也是首屏请求的条数。
  static const int defaultLimit = 100;

  Future<List<AuditEntry>> list(int limit) async {
    final safe = limit < 1 ? 1 : (limit > maxLimit ? maxLimit : limit);
    final resp = await _dio.get<dynamic>(
      '/api/audit',
      queryParameters: <String, dynamic>{'limit': safe},
    );
    return unwrapList<AuditEntry>(resp.data, AuditEntry.fromJson);
  }
}

final auditRepositoryProvider = Provider<AuditRepository>(
  (ref) => AuditRepository(ref.watch(jsonDioProvider)),
);
