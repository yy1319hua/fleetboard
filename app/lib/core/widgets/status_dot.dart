import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 语义状态色（固定不可挪用，仅表达状态）。对应 DESIGN.md 状态色。
enum StatusKind { ok, warn, danger, info, idle }

/// 将后端 connection_status 映射为状态色类型。
StatusKind statusFromConnection(String status) => switch (status) {
      'online' => StatusKind.ok,
      'offline' => StatusKind.danger,
      'unknown' => StatusKind.idle,
      _ => StatusKind.idle,
    };

/// 状态圆点（总览/详情通用）。直径默认 8，符合 4px 间距体系。
class StatusDot extends StatelessWidget {
  const StatusDot(
    this.kind, {
    super.key,
    this.size = 8,
  });

  final StatusKind kind;
  final double size;

  Color get _color {
    switch (kind) {
      case StatusKind.ok:
        return AppColors.ok;
      case StatusKind.warn:
        return AppColors.warn;
      case StatusKind.danger:
        return AppColors.danger;
      case StatusKind.info:
        return AppColors.info;
      case StatusKind.idle:
        return AppColors.idle;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _color,
        shape: BoxShape.circle,
      ),
    );
  }
}
