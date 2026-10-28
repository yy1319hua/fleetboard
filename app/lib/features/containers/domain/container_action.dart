import 'package:freezed_annotation/freezed_annotation.dart';

part 'container_action.freezed.dart';
part 'container_action.g.dart';

/// 容器操作类型（对齐后端 POST .../actions 的 body.action）。
enum ContainerActionType {
  start,
  stop,
  restart,
  rm;

  /// 传输值（后端接受的字面量）。
  String get wire => name;

  String get label => switch (this) {
        ContainerActionType.start => '启动',
        ContainerActionType.stop => '停止',
        ContainerActionType.restart => '重启',
        ContainerActionType.rm => '删除',
      };

  /// 不可逆操作：需全屏确认 + 手输容器名前 4 位。
  bool get dangerous =>
      this == ContainerActionType.restart || this == ContainerActionType.rm;
}

/// 操作结果（对齐后端 data: {container, action, output}）。
@freezed
class ContainerActionResult with _$ContainerActionResult {
  const factory ContainerActionResult({
    required String container,
    required String action,
    required String output,
  }) = _ContainerActionResult;

  factory ContainerActionResult.fromJson(Map<String, dynamic> json) =>
      _$ContainerActionResultFromJson(json);
}
