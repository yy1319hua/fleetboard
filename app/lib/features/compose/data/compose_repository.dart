import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/compose_models.dart';

/// Compose 编排仓储。
///
/// 契约（`internal/api/compose_handlers.go`）：
///  - `GET  /api/servers/:id/compose?dir=`            → `{roots, dir, dirs, files, skipped}`
///  - `GET  /api/servers/:id/compose/content?path=`   → `{path, content, size}`
///  - `PUT  /api/servers/:id/compose/content`         → `{path, size}`（原子写，保留权限属主）
///  - `POST /api/servers/:id/compose/actions`         → `{path, action, output}`（**同步**，非 202）
///
/// 三个易踩的坑：
///  1. `path` 走 query 参数（读）与 JSON body（写），都要传**绝对路径**且必须在服务端
///     白名单内，否则 400「路径不在允许的 compose 目录内」。
///  2. 内容为空时后端直接 400「内容为空，拒绝写入」——这不是 bug，是防误清空；
///     客户端要提前拦下并解释。
///  3. `up` / `down` / `restart` 常常超过 20s（拉镜像、等健康检查）。JSON 档位的
///     `receiveTimeout` 是 20s，用它会在动作**已经执行**的情况下报「请求超时」，
///     用户会以为没生效并重试一次。所以动作与后续可能的长时间写走 `streamDio`
///     （无 receiveTimeout，改由空闲看门狗兜底）。
class ComposeRepository {
  ComposeRepository(this._json, this._stream);

  final Dio _json;
  final Dio _stream;

  static final Random _random = Random.secure();

  Future<ComposeListing> list(int serverId, {String? dir}) async {
    final resp = await _json.get<dynamic>(
      '/api/servers/$serverId/compose',
      queryParameters: <String, dynamic>{
        if (dir != null && dir.isNotEmpty) 'dir': dir,
      },
    );
    return unwrap<ComposeListing>(resp.data, ComposeListing.fromJson);
  }

  Future<ComposeContent> read(int serverId, String path) async {
    final resp = await _json.get<dynamic>(
      '/api/servers/$serverId/compose/content',
      queryParameters: <String, dynamic>{'path': path},
    );
    return unwrap<ComposeContent>(resp.data, ComposeContent.fromJson);
  }

  /// 写回全文。服务端是「临时文件 + rename」的原子写，失败不会留半写状态。
  ///
  /// 返回服务端确认的字节数（`data.size`），与本地 `content.length` 不同：
  /// 中文注释占多个字节，用它做一次「写进去的和发出去的不一样吗」的粗校验。
  Future<int> write(int serverId, String path, String content) async {
    final resp = await _stream.put<dynamic>(
      '/api/servers/$serverId/compose/content',
      data: <String, dynamic>{'path': path, 'content': content},
    );
    final data = unwrap<Map<String, dynamic>>(resp.data, (json) => json);
    return (data['size'] as num?)?.toInt() ?? content.length;
  }

  /// 执行 compose 动作。
  ///
  /// 带 `X-Client-Op-Id`：后端幂等中间件对同键 60s 内的重复请求直接回放首次响应，
  /// 用来兜住「弱网重试」与「用户连点」导致的重复 up/down。每次真实点击生成一个新 id。
  Future<ComposeActionResult> runAction(
    int serverId,
    String path,
    String action,
  ) async {
    final resp = await _stream.post<dynamic>(
      '/api/servers/$serverId/compose/actions',
      data: <String, dynamic>{'path': path, 'action': action},
      options: Options(headers: <String, dynamic>{
        'X-Client-Op-Id': _newOpId(serverId, action),
      }),
    );
    return unwrap<ComposeActionResult>(resp.data, ComposeActionResult.fromJson);
  }

  static String _newOpId(int serverId, String action) {
    // 不引第三方 uuid：时间戳 + 随机数足以在 60s 窗口内避免碰撞。
    final now = DateTime.now().microsecondsSinceEpoch;
    final salt = _random.nextInt(1 << 32).toRadixString(16);
    return 'compose-$serverId-$action-$now-$salt';
  }
}

final composeRepositoryProvider = Provider<ComposeRepository>(
  (ref) => ComposeRepository(
    ref.watch(jsonDioProvider),
    ref.watch(streamDioProvider),
  ),
);
