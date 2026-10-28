import 'package:freezed_annotation/freezed_annotation.dart';

part 'alert_event.freezed.dart';
part 'alert_event.g.dart';

/// 告警事件（对齐后端 internal/model/models.go AlertEvent）。
@freezed
class AlertEvent with _$AlertEvent {
  const factory AlertEvent({
    required int id,
    @JsonKey(name: 'server_id') int? serverId,
    @JsonKey(name: 'rule_id') int? ruleId,
    required String severity,
    required String title,
    required String message,
    @JsonKey(name: 'is_read') required bool isRead,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _AlertEvent;

  factory AlertEvent.fromJson(Map<String, dynamic> json) =>
      _$AlertEventFromJson(json);
}
