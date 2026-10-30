import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/overview/domain/bootstrap.dart';

/// 总览数据快照（最后一次成功拉取的结果）。
///
/// 为什么需要它：冷启动到首帧只要几百毫秒，但 `/api/bootstrap` 要经过
/// Cloudflare Access + SSH 采集，弱网时 2~5 秒很常见。这段时间里页面只有
/// 背景色，看起来就是「灰屏/空白」。缓存让首屏立刻有内容，顶部标注数据时间，
/// 网络返回后静默覆盖——用户先看到「昨天的数据」，再看到「最新的数据」。
///
/// 版本号（`_v1`）与结构绑定：`BootstrapResponse` 增删必填字段时改版本号，
/// 旧缓存自然失效，不会出现「老 JSON 解析崩」。
class BootstrapCache {
  static const String _keyData = 'bootstrap_cache_v1';
  static const String _keyAt = 'bootstrap_cache_at_v1';

  /// 读缓存。没有、损坏、版本不符都返回 null（静默降级，不影响启动）。
  Future<({BootstrapResponse data, DateTime at})?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keyData);
      final atMs = prefs.getInt(_keyAt);
      if (raw == null || raw.isEmpty || atMs == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return (
        data: BootstrapResponse.fromJson(decoded),
        at: DateTime.fromMillisecondsSinceEpoch(atMs),
      );
    } on Object {
      // 缓存只是优化项：解析失败就当没有，绝不让它把启动流程带崩。
      return null;
    }
  }

  Future<void> save(BootstrapResponse data, DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyData, jsonEncode(data.toJson()));
      await prefs.setInt(_keyAt, at.millisecondsSinceEpoch);
    } on Object {
      // 写失败（磁盘满、插件异常）不影响正常使用。
    }
  }
}

final bootstrapCacheProvider = Provider<BootstrapCache>(
  (ref) => BootstrapCache(),
);

/// 当前展示的数据来自缓存时的「缓存时间」；网络数据到位后置回 null。
///
/// 单独一个 provider 而不是塞进 AsyncValue：`AsyncValue` 表达的是加载状态，
/// 而「数据是新的还是旧的」是正交信息，混进去会让所有 when 分支都要多判一次。
final overviewCacheAtProvider = StateProvider<DateTime?>((ref) => null);
