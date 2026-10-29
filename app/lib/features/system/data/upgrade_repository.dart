import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/panel_upgrade.dart';

/// 面板自更新仓储。
///
/// 为什么这里同时注入两个 dio：
///  - 业务端点（info / status / trigger / history）都挂在鉴权组，必须带 Bearer，
///    走 [jsonDioProvider]；
///  - health 是**判定升级成败的唯一依据**，它必须在「面板已经停服」时也能快速
///    得出结论，所以走 3s 全超时的 [probeDioProvider]。用 20s 超时的实例，
///    一次停服探测就要等 20s，界面会长时间停在「等待服务重启」不动。
class UpgradeRepository {
  UpgradeRepository({
    required Dio jsonDio,
    required Dio probeDio,
  })  : _json = jsonDio,
        _probe = probeDio;

  final Dio _json;
  final Dio _probe;

  Future<PanelUpgradeInfo> info() async {
    final resp = await _json.get<dynamic>('/api/system/upgrade');
    return unwrap<PanelUpgradeInfo>(resp.data, PanelUpgradeInfo.fromJson);
  }

  /// 升级窗口内的状态轮询：**任何失败都返回 null**。
  ///
  /// 停服期间 Cloudflare 会回 502，这与「新版本起不来」在 HTTP 层面完全同形，
  /// 所以这里不做任何判定，只负责把「没拿到」这件事如实传上去。
  Future<UpgradeStatus?> statusOrNull() async {
    try {
      final resp = await _json.get<dynamic>('/api/system/upgrade/status');
      return unwrap<UpgradeStatus>(resp.data, UpgradeStatus.fromJson);
    } on Object {
      return null;
    }
  }

  /// health 探活：只认「解析出非空 version」。
  ///
  /// 不做任何状态码判断是有意为之：502 既可能是正常重启，也可能是真的起不来，
  /// 拿它做判据必然误判。能分辨两种情况的只有「版本号对不对」和「等了多久」。
  Future<String?> healthVersionOrNull() async {
    try {
      final resp = await _probe.get<dynamic>('/api/health');
      if ((resp.statusCode ?? 0) != 200) return null;
      final body = resp.data;
      if (body is! Map) return null;
      final data = body['data'];
      final version = data is Map ? data['version'] : body['version'];
      if (version is String && version.trim().isNotEmpty) return version.trim();
      return null;
    } on Object {
      return null;
    }
  }

  /// 触发升级（危险操作：带密码 + 幂等 OpId）。
  ///
  /// 这一步在「升级窗口之外」，失败必须让用户看见（密码错、已有任务、环境不满足），
  /// 与窗口内的静默轮询是两种不同的处理原则。
  Future<UpgradeStatus> trigger({
    required String password,
    required String opId,
    String? targetVersion,
  }) async {
    final resp = await _json.post<dynamic>(
      '/api/system/upgrade',
      data: <String, dynamic>{
        'password': password,
        if (targetVersion != null && targetVersion.trim().isNotEmpty)
          'target_version': targetVersion.trim(),
      },
      options: Options(headers: <String, dynamic>{'X-Client-Op-Id': opId}),
    );
    return unwrap<UpgradeStatus>(resp.data, UpgradeStatus.fromJson);
  }

  /// 升级历史分页。
  ///
  /// `/api/system/upgrades` 尚未上线时会回 404：此时返回「空历史」，
  /// 页面展示空态文案——把「功能还没做」渲染成「读取失败」会让用户反复点重试。
  Future<UpgradeHistory> history({int limit = 20, int offset = 0}) async {
    try {
      final resp = await _json.get<dynamic>(
        '/api/system/upgrades',
        queryParameters: <String, dynamic>{
          'limit': '$limit',
          'offset': '$offset',
        },
      );
      return unwrap<UpgradeHistory>(resp.data, UpgradeHistory.fromJson);
    } on Object catch (e) {
      if (_isNotFound(e)) {
        return const UpgradeHistory(
          items: <UpgradeRecord>[],
          total: 0,
          endpointMissing: true,
        );
      }
      rethrow;
    }
  }

  static bool _isNotFound(Object error) {
    if (error is DioException) {
      final inner = error.error;
      if (inner is ApiException && inner.code == 404) return true;
      return error.response?.statusCode == 404;
    }
    if (error is ApiException) return error.code == 404;
    return false;
  }
}

final upgradeRepositoryProvider = Provider<UpgradeRepository>((ref) {
  return UpgradeRepository(
    jsonDio: ref.watch(jsonDioProvider),
    probeDio: ref.watch(probeDioProvider),
  );
});

/// 版本与可升级性（页面首屏）。
final panelUpgradeInfoProvider =
    FutureProvider.autoDispose<PanelUpgradeInfo>((ref) {
  return ref.watch(upgradeRepositoryProvider).info();
});
