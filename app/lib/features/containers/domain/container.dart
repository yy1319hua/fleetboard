import 'package:freezed_annotation/freezed_annotation.dart';

part 'container.freezed.dart';
part 'container.g.dart';

/// 容器（对齐后端 internal/docker/service.go 的 Container）。
@freezed
class Container with _$Container {
  const factory Container({
    required String id,
    required String name,
    required String image,
    /// running / exited / paused / created / ...
    required String state,
    /// 人类可读状态串（含运行时长等）。
    required String status,
    @JsonKey(name: 'created_at') required String createdAt,
    /// 端口映射串（可能为空）。
    required String ports,
  }) = _Container;

  factory Container.fromJson(Map<String, dynamic> json) =>
      _$ContainerFromJson(json);
}
