import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../data/alert_rules_repository.dart';
import '../domain/alert_rule.dart';

/// 告警规则列表状态。
///
/// 用 `AsyncValue<List<AlertRule>>`：页面只有四态，没有草稿之类的本地状态
/// （草稿在编辑页里活一次就丢），没必要再包一层自定义 State。
class AlertRulesNotifier extends StateNotifier<AsyncValue<List<AlertRule>>> {
  AlertRulesNotifier(this._repo) : super(const AsyncValue.loading()) {
    load();
  }

  final AlertRulesRepository _repo;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await _fetch();
  }

  Future<void> refresh() => _fetch();

  Future<void> _fetch() async {
    try {
      state = AsyncValue.data(await _repo.list());
    } on Object catch (e, st) {
      // 有旧数据时保留：弱网下旧列表比错误页有用。
      if (state is! AsyncData<List<AlertRule>>) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  /// 开关切换：先本地翻转、再发 PUT，失败回滚。
  ///
  /// 为什么乐观更新：开关是高频轻操作，等一个来回（SSH 平台通常 100–500ms，
  /// 弱网更久）再动会让用户以为没点中，进而连点。失败必须回滚——否则界面
  /// 显示"已开启"而服务端还是关的，用户会以为告警在生效。
  Future<void> toggle(AlertRule rule, bool enabled) async {
    final snapshot = state.valueOrNull;
    if (snapshot == null) return;

    state = AsyncValue.data(<AlertRule>[
      for (final item in snapshot)
        item.id == rule.id ? item.copyWith(enabled: enabled) : item,
    ]);

    try {
      final updated = await setRuleEnabled(_repo, rule.id, enabled);
      // 用服务端返回的规则覆盖本地（含其他字段，保证一致性）。
      final current = state.valueOrNull ?? const <AlertRule>[];
      state = AsyncValue.data(<AlertRule>[
        for (final item in current)
          item.id == updated.id ? updated : item,
      ]);
    } on Object {
      state = AsyncValue.data(snapshot);
      rethrow;
    }
  }

  /// 新建或编辑保存。返回保存后的规则。
  ///
  /// `origin == null` 走创建；否则只 PUT 变化字段（merge 语义，见仓储注释）。
  Future<AlertRule> save({
    required AlertRuleDraft draft,
    AlertRule? origin,
  }) async {
    if (origin == null) {
      final created = await _repo.create(draft);
      final current = state.valueOrNull ?? const <AlertRule>[];
      state = AsyncValue.data(<AlertRule>[...current, created]);
      return created;
    }

    final patch = buildRulePatch(origin, draft);
    if (patch.isEmpty) {
      throw const ApiException(message: '没有任何改动');
    }
    final updated = await _repo.update(origin.id, patch);
    final current = state.valueOrNull ?? const <AlertRule>[];
    state = AsyncValue.data(<AlertRule>[
      for (final item in current) item.id == updated.id ? updated : item,
    ]);
    return updated;
  }

  Future<void> remove(AlertRule rule) async {
    await _repo.delete(rule.id);
    final current = state.valueOrNull ?? const <AlertRule>[];
    state = AsyncValue.data(<AlertRule>[
      for (final item in current)
        if (item.id != rule.id) item,
    ]);
  }
}

final alertRulesProvider =
    StateNotifierProvider<AlertRulesNotifier, AsyncValue<List<AlertRule>>>(
  (ref) => AlertRulesNotifier(ref.watch(alertRulesRepositoryProvider)),
);
