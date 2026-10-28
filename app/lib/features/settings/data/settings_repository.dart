import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/settings.dart';

/// 设置仓储：GET /api/settings（鉴权）。首版只读。
class SettingsRepository {
  SettingsRepository(this._dio);

  final Dio _dio;

  Future<SettingsResponse> getSettings() async {
    final resp = await _dio.get<dynamic>('/api/settings');
    return unwrap<SettingsResponse>(resp.data, SettingsResponse.fromJson);
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(dioProvider)),
);
