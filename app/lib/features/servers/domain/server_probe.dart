import '../../overview/domain/bootstrap.dart';

/// 一次体检（采配置 + 探 Docker/sftp）的结果。
///
/// 只在两个时机产生：首次添加服务器、用户点「刷新配置」。
/// 后端在体检失败时仍然会把服务器存下来，所以 [ok] 为 false 不代表添加失败，
/// 只代表配置卡暂时没有内容。
class ProbeOutcome {
  const ProbeOutcome({
    required this.ok,
    this.hasDocker = -1,
    this.hasSftp = -1,
    this.error = '',
    this.warnings = const <String>[],
  });

  /// 什么都不知道的初值：调用方据此显示「尚未检测」。
  const ProbeOutcome.unknown()
      : ok = false,
        hasDocker = -1,
        hasSftp = -1,
        error = '',
        warnings = const <String>[];

  final bool ok;

  /// -1 未检测、0 不支持、1 支持。
  final int hasDocker;
  final int hasSftp;

  /// 失败原因（连接不上、认证失败等），成功时为空。
  final String error;

  /// 主流程成功但个别项没探到的说明。
  final List<String> warnings;

  bool get dockerAvailable => hasDocker != 0;
  bool get sftpAvailable => hasSftp != 0;

  factory ProbeOutcome.fromJson(Map<String, dynamic> json) {
    int i(String key) {
      final v = json[key];
      return v is num ? v.toInt() : -1;
    }

    final rawWarnings = json['warnings'];
    return ProbeOutcome(
      ok: json['ok'] == true,
      hasDocker: i('has_docker'),
      hasSftp: i('has_sftp'),
      error: (json['error'] as String?) ?? '',
      warnings: rawWarnings is List
          ? rawWarnings.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }
}

/// 添加服务器的返回：机器本身 + 体检结果。
class ServerCreation {
  const ServerCreation({required this.server, required this.probe});

  final Server server;
  final ProbeOutcome probe;
}

/// 按需采样的一次快照（仅「仅保存」的机器会用）。
class SampleSnapshot {
  const SampleSnapshot({
    required this.cpuPct,
    required this.memPct,
    required this.diskPct,
    required this.load1,
  });

  final double cpuPct;
  final double memPct;
  final double diskPct;
  final double load1;

  factory SampleSnapshot.fromJson(Map<String, dynamic> json) {
    double d(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    }

    return SampleSnapshot(
      cpuPct: d('cpu_pct'),
      memPct: d('mem_pct'),
      diskPct: d('disk_pct'),
      load1: d('load1'),
    );
  }
}
