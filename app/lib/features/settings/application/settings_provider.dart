import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_repository.dart';
import '../domain/settings.dart';

/// 设置页数据（首版只读）。鉴权 GET /api/settings。
///
/// 用 FutureProvider：页面 watch 即拉取；登出/切账号后由 Riverpod 自动失效重取。
final settingsProvider = FutureProvider<SettingsResponse>((ref) async {
  return ref.watch(settingsRepositoryProvider).getSettings();
});
