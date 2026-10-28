import 'package:freezed_annotation/freezed_annotation.dart';

part 'bootstrap.freezed.dart';
part 'bootstrap.g.dart';

/// 被管服务器（对齐后端 model.Server）。
@freezed
class Server with _$Server {
  const factory Server({
    required int id,
    required String name,
    required String host,
    required int port,
    @JsonKey(name: 'ssh_user') required String sshUser,
    @JsonKey(name: 'auth_method') required String authMethod,
    @JsonKey(name: 'connection_status') required String connectionStatus,
    @JsonKey(name: 'last_heartbeat') DateTime? lastHeartbeat,
    required String tags,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _Server;

  factory Server.fromJson(Map<String, dynamic> json) => _$ServerFromJson(json);
}

/// 服务器最新指标（对齐后端 model.ServerMetric，字段名含下划线）。
@freezed
class MetricLatest with _$MetricLatest {
  const factory MetricLatest({
    required int id,
    @JsonKey(name: 'server_id') required int serverId,
    required DateTime ts,
    @JsonKey(name: 'cpu_pct') required double cpuPct,
    @JsonKey(name: 'mem_pct') required double memPct,
    @JsonKey(name: 'disk_pct') required double diskPct,
    @JsonKey(name: 'load1') required double load1,
    @JsonKey(name: 'net_in_kbps') required double netInKbps,
    @JsonKey(name: 'net_out_kbps') required double netOutKbps,
  }) = _MetricLatest;

  factory MetricLatest.fromJson(Map<String, dynamic> json) =>
      _$MetricLatestFromJson(json);
}

/// GET /api/bootstrap 聚合响应（对齐 bootstrapHandler）。
///
/// metrics 以服务器 id（字符串）为键；某机指标缺失则该 key 不出现（前端按 key 取，缺失即无摘要）。
@freezed
class BootstrapResponse with _$BootstrapResponse {
  const factory BootstrapResponse({
    required List<Server> servers,
    required Map<String, MetricLatest> metrics,
    @JsonKey(name: 'unreadAlerts') required int unreadAlerts,
    required String version,
    required int schema,
    required int ver,
  }) = _BootstrapResponse;

  factory BootstrapResponse.fromJson(Map<String, dynamic> json) =>
      _$BootstrapResponseFromJson(json);
}
