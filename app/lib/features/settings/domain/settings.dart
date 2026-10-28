import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';
part 'settings.g.dart';

/// 只读元信息（对齐 settings_handlers 的 readonlyView）。
@freezed
class ReadonlyMeta with _$ReadonlyMeta {
  const factory ReadonlyMeta({
    /// 主密钥尾 4 位掩码。
    @JsonKey(name: 'key_masked') required String keyMasked,
    /// 服务端口。
    required int port,
  }) = _ReadonlyMeta;

  factory ReadonlyMeta.fromJson(Map<String, dynamic> json) =>
      _$ReadonlyMetaFromJson(json);
}

/// GET /api/settings 响应（对齐 getSettingsHandler）。
///
/// items 为联合形态：非敏感项为字符串原值；敏感项为 {"masked":..., "set":bool}。
/// 以 [Map<String, dynamic>] 承接，再由 [entries] 归一化为展示模型，避免对后端 key 硬编码。
@freezed
class SettingsResponse with _$SettingsResponse {
  const SettingsResponse._();

  const factory SettingsResponse({
    required Map<String, dynamic> items,
    required ReadonlyMeta readonly,
  }) = _SettingsResponse;

  factory SettingsResponse.fromJson(Map<String, dynamic> json) =>
      _$SettingsResponseFromJson(json);

  /// 归一化后的展示条目（按后端返回顺序）。
  List<SettingEntry> get entries => SettingEntry.normalize(items);
}

/// 设置展示条目（前端归一化后的稳定形态）。
class SettingEntry {
  const SettingEntry({
    required this.key,
    required this.label,
    required this.displayValue,
    required this.isSecret,
    required this.isSet,
  });

  final String key;
  final String label;
  final String displayValue;
  final bool isSecret;
  final bool isSet;

  static const Map<String, String> _labels = <String, String>{
    'monitor.interval': '监控间隔（秒）',
    'metrics.retention_days': '指标保留天数',
    'monitor.offline_threshold': '离线判定阈值（次）',
    'compose.roots': 'Compose 根目录',
    'pushplus.token': 'PushPlus 通知令牌',
    'jwt.secret': 'JWT 签名密钥',
  };

  /// 将后端 items 联合值归一化：敏感项取掩码，非敏感项取原值。
  static List<SettingEntry> normalize(Map<String, dynamic> items) {
    return items.entries.map((e) {
      final key = e.key;
      final value = e.value;
      final label = _labels[key] ?? key;
      if (value is Map<String, dynamic>) {
        final masked = (value['masked'] as String?) ?? '';
        final set = (value['set'] as bool?) ?? false;
        return SettingEntry(
          key: key,
          label: label,
          displayValue: set ? masked : '（未设置）',
          isSecret: true,
          isSet: set,
        );
      }
      return SettingEntry(
        key: key,
        label: label,
        displayValue: value?.toString() ?? '',
        isSecret: false,
        isSet: true,
      );
    }).toList();
  }
}
