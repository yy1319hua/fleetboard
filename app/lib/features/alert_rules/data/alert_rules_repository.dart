import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/alert_rule.dart';

/// 告警规则仓储。
///
/// 契约（`internal/api/alert_handlers.go`）：
///  - `GET    /api/alert-rules`      → `[AlertRule]`
///  - `POST   /api/alert-rules`      → **201** + 新建的规则
///  - `PUT    /api/alert-rules/:id`  → **merge 语义**：只传要改的字段
///  - `DELETE /api/alert-rules/:id`  → `{deleted}`
///
/// merge 的两个硬约束：
///  1. `server_id` 只要出现在 body 里就 400（"不支持修改规则归属"）——所以 patch
///     里绝不能带它，哪怕是原值。
///  2. 没传的字段保持原值。反过来讲，用 PUT 发全量字段是危险的：客户端一旦漏了
///     `notify_channels`，服务端不会报错，只是把它清空。
class AlertRulesRepository {
  AlertRulesRepository(this._dio);

  final Dio _dio;

  Future<List<AlertRule>> list() async {
    final resp = await _dio.get<dynamic>('/api/alert-rules');
    return unwrapList<AlertRule>(resp.data, AlertRule.fromJson);
  }

  Future<AlertRule> create(AlertRuleDraft draft) async {
    final resp = await _dio.post<dynamic>(
      '/api/alert-rules',
      data: <String, dynamic>{
        if (draft.serverId != null) 'server_id': draft.serverId,
        'metric': draft.metric,
        'operator': draft.operator,
        'threshold': draft.threshold,
        'severity': draft.severity,
        'enabled': draft.enabled,
        'notify_channels': draft.notifyChannels,
      },
    );
    return unwrap<AlertRule>(resp.data, AlertRule.fromJson);
  }

  /// 部分更新：只提交真正变化的字段。
  Future<AlertRule> update(int id, Map<String, dynamic> patch) async {
    if (patch.isEmpty) {
      throw const ApiException(message: '没有需要保存的改动');
    }
    // 防御：merge 接口不接 server_id，带上就 400。这里直接剥离并留注释，
    // 避免以后有人在 patch 里加字段时踩坑。
    final body = Map<String, dynamic>.from(patch)..remove('server_id');
    final resp = await _dio.put<dynamic>('/api/alert-rules/$id', data: body);
    return unwrap<AlertRule>(resp.data, AlertRule.fromJson);
  }

  Future<void> delete(int id) async {
    await _dio.delete<dynamic>('/api/alert-rules/$id');
  }
}

final alertRulesRepositoryProvider = Provider<AlertRulesRepository>(
  (ref) => AlertRulesRepository(ref.watch(jsonDioProvider)),
);

/// 开关切换：只发 `enabled`（merge 语义的最小 patch）。
Future<AlertRule> setRuleEnabled(
  AlertRulesRepository repo,
  int id,
  bool enabled,
) =>
    repo.update(id, <String, dynamic>{'enabled': enabled});

/// 对比草稿与原规则，算出需要 PUT 的最小 patch。
///
/// 为什么要在客户端算 diff 而不是直接发全量：merge 接口的正确用法就是"只发改动"，
/// 发全量虽然也能工作，但一旦某个字段在客户端模型里缺失（例如以后后端加了新字段），
/// 就成了"用旧值覆盖新值"的静默数据丢失。
Map<String, dynamic> buildRulePatch(AlertRule origin, AlertRuleDraft draft) {
  final patch = <String, dynamic>{};
  if (draft.metric != origin.metric) patch['metric'] = draft.metric;
  if (draft.operator != origin.operator) patch['operator'] = draft.operator;
  if (draft.threshold != origin.threshold) patch['threshold'] = draft.threshold;
  if (draft.severity != origin.severity) patch['severity'] = draft.severity;
  if (draft.enabled != origin.enabled) patch['enabled'] = draft.enabled;
  if (draft.notifyChannels != origin.notifyChannels) {
    patch['notify_channels'] = draft.notifyChannels;
  }
  return patch;
}
