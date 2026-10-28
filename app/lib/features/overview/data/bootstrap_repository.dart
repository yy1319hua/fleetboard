import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/bootstrap.dart';

/// 总览仓储：GET /api/bootstrap（鉴权）。
class BootstrapRepository {
  BootstrapRepository(this._dio);

  final Dio _dio;

  Future<BootstrapResponse> getBootstrap() async {
    final resp = await _dio.get<dynamic>('/api/bootstrap');
    return unwrap<BootstrapResponse>(resp.data, BootstrapResponse.fromJson);
  }
}

final bootstrapRepositoryProvider = Provider<BootstrapRepository>(
  (ref) => BootstrapRepository(ref.watch(dioProvider)),
);
