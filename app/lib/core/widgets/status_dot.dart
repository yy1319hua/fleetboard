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

/// 状态圆点（内部零件，页面一律用 [StatusLabel]，不要直接构造）。
///
/// 直径默认 8（契约固定值），不再允许 6/14 这类散落尺寸。
/// [semanticLabel] 给读屏用的文字。契约要求状态不能只靠颜色传达，
/// 所以即使这里只画一个点，也必须把语义挂在 Semantics 上；不传时
/// 由 [StatusLabel] 负责承担语义。
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
/// 这是 App 里**唯一**对外暴露的状态组件，[StatusDot] 降级为内部零件。
/// [compact] = true 时只画圆点并把 [label] 挂到 Semantics：用于
/// `ListTile.leading` 这类宽度受限的位置，或旁边页面文案已展示同一状态词
/// 的地方（避免重复文字挤占空间）。契约「状态不能只靠颜色」由 Semantics
/// 读屏通道 + 相邻中文文案共同满足。
class StatusLabel extends StatelessWidget {
  const StatusLabel({
    super.key,
    required this.kind,
    required this.label,
    this.compact = false,
    this.mainAxisSize = MainAxisSize.min,
  });

  final StatusKind kind;
  final String label;

  /// true：仅 8px 圆点 + 语义标签；false：圆点 + 12px 中文状态词。
  final bool compact;

  /// 详情页状态行希望撑满宽度时传 [MainAxisSize.max]。
  final MainAxisSize mainAxisSize;

  @override
  Widget build(BuildContext context) {
    // 圆点固定 8px（契约值），不再暴露 dotSize 以免 6/14 散落尺寸回潮。
    final dot = StatusDot(kind);
    if (compact) {
      // 紧凑模式：圆点本身不带文字，必须自己包 Semantics，否则读屏
      // 只剩下「一个色块」，颜色就成了唯一状态信号。
      return Semantics(label: label, container: true, child: dot);
    }
    // 完整模式：用 MergeSemantics 把圆点与文字合成一个语义节点，
    // 文字由 Text 自己提供。若外层再设一个相同的 label，语义树会合并出
    // 重复节点，读屏读两遍且 find.bySemanticsLabel 匹配异常。
    return MergeSemantics(
      child: Row(
        mainAxisSize: mainAxisSize,
        children: <Widget>[
          dot,
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
