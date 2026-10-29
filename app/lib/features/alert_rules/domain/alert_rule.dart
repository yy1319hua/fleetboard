/// 告警规则模型（对齐 `internal/model.AlertRule` 与 `alert_handlers.go`）。
///
/// 三处必须按后端真相来、不能按"产品直觉"来：
///  1. **没有规则名字段**，也没有"持续时间/持续几分钟"。列表里的标题是从
///     `metric + operator + threshold` 拼出来的（拼在前端，不动模型）。
///  2. `notify_channels` 是逗号分隔的字符串（如 `"inapp,pushplus"`）。而
///     `internal/alert/engine.go` 里**每条命中的规则都会写通知中心**（inapp 恒定），
///     `notify_channels` 只决定要不要再推 PushPlus。所以表单里不能给"应用内通知"
///     开关——关了也不会生效，那是假开关。
///  3. `metric` 后端白名单含 `offline`，但告警引擎的 `MetricValue` 不处理它
///     （注释明说"offline 由连接状态单独判断"，而该判断目前没有接上规则）。
///     也就是说建一条 offline 规则**永远不会触发**，因此表单不提供该选项。
library;

import '../../../core/widgets/status_dot.dart';

/// 会被告警引擎真正评估的指标（只有这三个）。
enum AlertMetric {
  cpuPct('cpu_pct', 'CPU 使用率'),
  memPct('mem_pct', '内存使用率'),
  diskPct('disk_pct', '磁盘使用率');

  const AlertMetric(this.wire, this.label);

  final String wire;
  final String label;

  static AlertMetric? tryParse(String wire) {
    for (final metric in values) {
      if (metric.wire == wire) return metric;
    }
    return null;
  }
}

/// 比较符，与后端 `validOperator` 完全一致。
const List<String> kAlertOperators = <String>['>', '>=', '<', '<=', '='];

/// 级别，与后端 `validSeverity` 完全一致。
const List<String> kAlertSeverities = <String>['info', 'warn', 'critical'];

String alertSeverityLabel(String severity) => switch (severity) {
      'info' => '提示',
      'warn' => '警告',
      'critical' => '严重',
      _ => severity.isEmpty ? '未知' : severity,
    };

StatusKind alertSeverityKind(String severity) => switch (severity) {
      'critical' => StatusKind.danger,
      'warn' => StatusKind.warn,
      'info' => StatusKind.info,
      _ => StatusKind.idle,
    };

/// 阈值文本：整数不显示 `.0`。
String formatThreshold(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toString();
}

class AlertRule {
  const AlertRule({
    required this.id,
    required this.serverId,
    required this.metric,
    required this.operator,
    required this.threshold,
    required this.severity,
    required this.enabled,
    required this.notifyChannels,
    required this.createdAt,
  });

  final int id;

  /// null = 全局规则（对所有服务器生效）。
  final int? serverId;

  final String metric;
  final String operator;
  final double threshold;
  final String severity;
  final bool enabled;
  final String notifyChannels;
  final DateTime? createdAt;

  AlertMetric? get metricEnum => AlertMetric.tryParse(metric);

  /// 指标展示名；遇到模型里没有的（例如历史数据里的 offline）如实显示原值，
  /// 不假装它是受支持的指标。
  String get metricLabel => metricEnum?.label ?? '$metric（引擎不支持，不会触发）';

  String get title => '$metricLabel $operator ${formatThreshold(threshold)}%';

  bool get isGlobal => serverId == null;

  Set<String> get channels => notifyChannels
      .split(',')
      .map((channel) => channel.trim())
      .where((channel) => channel.isNotEmpty)
      .toSet();

  bool get pushplusEnabled => channels.contains('pushplus');

  String get scopeLabel => isGlobal ? '全局' : '服务器 #$serverId';

  String get channelLabel {
    final list = <String>[
      '应用内',
      if (pushplusEnabled) 'PushPlus',
    ];
    return list.join(' + ');
  }

  AlertRule copyWith({
    String? metric,
    String? operator,
    double? threshold,
    String? severity,
    bool? enabled,
    String? notifyChannels,
  }) {
    return AlertRule(
      id: id,
      serverId: serverId,
      metric: metric ?? this.metric,
      operator: operator ?? this.operator,
      threshold: threshold ?? this.threshold,
      severity: severity ?? this.severity,
      enabled: enabled ?? this.enabled,
      notifyChannels: notifyChannels ?? this.notifyChannels,
      createdAt: createdAt,
    );
  }

  factory AlertRule.fromJson(Map<String, dynamic> json) {
    final rawCreated = json['created_at'];
    return AlertRule(
      id: (json['id'] as num?)?.toInt() ?? 0,
      serverId: (json['server_id'] as num?)?.toInt(),
      metric: (json['metric'] as String?) ?? '',
      operator: (json['operator'] as String?) ?? '>',
      threshold: (json['threshold'] as num?)?.toDouble() ?? 0,
      severity: (json['severity'] as String?) ?? 'warn',
      enabled: json['enabled'] == true,
      notifyChannels: (json['notify_channels'] as String?) ?? '',
      createdAt:
          rawCreated is String ? DateTime.tryParse(rawCreated)?.toLocal() : null,
    );
  }
}

/// 表单里的可编辑值（与 [AlertRule] 分开：编辑时要能表达"还没保存"的状态）。
class AlertRuleDraft {
  const AlertRuleDraft({
    required this.metric,
    required this.operator,
    required this.threshold,
    required this.severity,
    required this.enabled,
    required this.pushplus,
    required this.serverId,
  });

  final String metric;
  final String operator;
  final double threshold;
  final String severity;
  final bool enabled;
  final bool pushplus;
  final int? serverId;

  /// 新建时的默认值：CPU > 80% 全局规则，默认开启、只写通知中心。
  factory AlertRuleDraft.initial() => const AlertRuleDraft(
        metric: 'cpu_pct',
        operator: '>',
        threshold: 80,
        severity: 'warn',
        enabled: true,
        pushplus: false,
        serverId: null,
      );

  factory AlertRuleDraft.fromRule(AlertRule rule) => AlertRuleDraft(
        metric: rule.metric,
        operator: rule.operator,
        threshold: rule.threshold,
        severity: rule.severity,
        enabled: rule.enabled,
        pushplus: rule.pushplusEnabled,
        serverId: rule.serverId,
      );

  /// `notify_channels` 的拼装：inapp 恒定在，pushplus 按开关加。
  ///
  /// 为什么不提供"关闭应用内"：引擎对每条命中的规则都会 `InsertAlertEvent`，
  /// `notify_channels` 只影响 PushPlus 推送（见 `alert/engine.go`）。
  /// 给一个关不掉 inapp 的开关就是骗人。
  String get notifyChannels => pushplus ? 'inapp,pushplus' : 'inapp';
}
