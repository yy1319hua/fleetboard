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

/// 状态色 -> 中文状态词。
///
/// 契约 §7「不用颜色作为唯一状态信号」：读屏与色觉障碍用户必须能读到文字。
/// 这是唯一的词表，不要在页面里各写一份「在线 / 运行中 / 已连接」。
String statusKindLabel(StatusKind kind) => switch (kind) {
      StatusKind.ok => '正常',
      StatusKind.warn => '警告',
      StatusKind.danger => '异常',
      StatusKind.info => '进行中',
      StatusKind.idle => '未知',
    };

/// 连接状态的中文文案（比通用词更贴切：online=在线 / offline=离线）。
String connectionStatusLabel(String status) => switch (status) {
      'online' => '在线',
      'offline' => '离线',
      'unknown' => '未知',
      _ => '未知',
    };

/// 容器状态的中文文案。
String containerStateLabel(String state) {
  if (state == 'running') return '运行中';
  if (state == 'exited') return '已退出';
  if (state == 'paused') return '已暂停';
  if (state == 'restarting') return '重启中';
  if (state == 'created') return '已创建';
  if (state == 'dead') return '已失效';
  return state.isEmpty ? '未知' : state;
}

/// 状态圆点（总览/详情通用）。直径默认 8，符合 4px 间距体系。
///
/// [semanticLabel] 给读屏用的文字。契约要求状态不能只靠颜色传达，
/// 所以即使这里只画一个点，也必须把语义挂在 Semantics 上；不传时
/// 由 [StatusLabel] 负责在旁边显示文字并承担语义。
class StatusDot extends StatelessWidget {
  const StatusDot(
    this.kind, {
    super.key,
    this.size = 8,
    this.semanticLabel,
  });

  final StatusKind kind;
  final double size;

  /// 为空时不加 Semantics（调用方已在别处提供文字），非空时读屏可读。
  final String? semanticLabel;

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
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _color,
        shape: BoxShape.circle,
      ),
    );
    final label = semanticLabel;
    if (label == null) return dot;
    return Semantics(label: label, child: dot);
  }
}

/// 状态徽标：8px 圆点 + 12px 中文状态词 + 语义标签（DESIGN.md §4）。
///
/// 布局允许显示文字时用这个；ListTile.leading 这类宽度受限的位置
/// 仍用 [StatusDot] 并传 semanticLabel，靠页面里的文字承担第二通道。
class StatusLabel extends StatelessWidget {
  const StatusLabel({
    super.key,
    required this.kind,
    required this.label,
    this.dotSize = 8,
    this.mainAxisSize = MainAxisSize.min,
  });

  final StatusKind kind;
  final String label;
  final double dotSize;

  /// 详情页状态行希望撑满宽度时传 [MainAxisSize.max]。
  final MainAxisSize mainAxisSize;

  @override
  Widget build(BuildContext context) {
    // 用 MergeSemantics 把圆点与文字合成一个语义节点，文字由 Text 自己提供。
    // 若外层再设一个相同的 label，语义树会合并出重复节点，读屏会读两遍，
    // 且 find.bySemanticsLabel 会匹配异常。
    return MergeSemantics(
      child: Row(
        mainAxisSize: mainAxisSize,
        children: <Widget>[
          StatusDot(kind, size: dotSize),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
