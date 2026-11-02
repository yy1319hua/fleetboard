import '../../files/domain/file_sizes.dart';

/// 一个挂载点的磁盘占用（对齐后端 `model.DiskUsage`）。
class DiskUsage {
  const DiskUsage({
    required this.device,
    required this.mount,
    required this.totalKb,
    required this.usedKb,
    required this.availKb,
    required this.usedPct,
  });

  final String device;
  final String mount;
  final int totalKb;
  final int usedKb;
  final int availKb;
  final double usedPct;

  factory DiskUsage.fromJson(Map<String, dynamic> json) {
    int i(String key) {
      final v = json[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    double d(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    }

    return DiskUsage(
      device: (json['device'] as String?) ?? '',
      mount: (json['mount'] as String?) ?? '',
      totalKb: i('total_kb'),
      usedKb: i('used_kb'),
      availKb: i('avail_kb'),
      usedPct: d('used_pct'),
    );
  }

  String get totalText => kbToText(totalKb);
  String get usedText => kbToText(usedKb);
}

/// 主机静态配置（对齐后端 `model.ServerFacts`）。
///
/// 与 [MetricPoint] 的区别：那份是「现在怎么样」（30 秒一条），
/// 这份是「这台机器是什么样」（每小时刷新）。概览的配置卡只读这里。
class ServerFacts {
  const ServerFacts({
    required this.serverId,
    required this.cpuModel,
    required this.cpuCores,
    required this.memTotalKb,
    required this.swapTotalKb,
    required this.osName,
    required this.kernel,
    required this.arch,
    required this.hostname,
    required this.uptimeSec,
    required this.virt,
    required this.disks,
    required this.collectedAt,
  });

  final int serverId;
  final String cpuModel;
  final int cpuCores;
  final int memTotalKb;
  final int swapTotalKb;
  final String osName;
  final String kernel;
  final String arch;
  final String hostname;
  final int uptimeSec;
  final String virt;
  final List<DiskUsage> disks;
  final DateTime collectedAt;

  factory ServerFacts.fromJson(Map<String, dynamic> json) {
    int i(String key) {
      final v = json[key];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    String s(String key) => (json[key] as String?) ?? '';

    final rawDisks = json['disks'];
    final disks = <DiskUsage>[];
    if (rawDisks is List) {
      for (final item in rawDisks) {
        if (item is Map<String, dynamic>) disks.add(DiskUsage.fromJson(item));
      }
    }

    final rawTs = json['collected_at'];
    final ts = rawTs is String ? DateTime.tryParse(rawTs)?.toLocal() : null;

    return ServerFacts(
      serverId: i('server_id'),
      cpuModel: s('cpu_model'),
      cpuCores: i('cpu_cores'),
      memTotalKb: i('mem_total_kb'),
      swapTotalKb: i('swap_total_kb'),
      osName: s('os_name'),
      kernel: s('kernel'),
      arch: s('arch'),
      hostname: s('hostname'),
      uptimeSec: i('uptime_sec'),
      virt: s('virt'),
      disks: disks,
      collectedAt: ts ?? DateTime.now(),
    );
  }

  String get memTotalText => kbToText(memTotalKb);
  String get swapTotalText => kbToText(swapTotalKb);

  /// 虚拟化类型 → 中文。未知值原样返回，便于发现新类型。
  String get virtLabel {
    switch (virt) {
      case 'none':
        return '物理机';
      case 'kvm':
        return 'KVM 虚拟机';
      case 'vmware':
        return 'VMware 虚拟机';
      case 'docker':
      case 'podman':
        return '容器';
      case 'lxc':
        return 'LXC 容器';
      case '':
      case 'unknown':
        return '—';
      default:
        return virt;
    }
  }

  /// 运行时长 → 「12 天 3 小时」这类粗粒度文案（精确到分没有意义）。
  String get uptimeText {
    if (uptimeSec <= 0) return '—';
    final d = uptimeSec ~/ 86400;
    final h = (uptimeSec % 86400) ~/ 3600;
    final m = (uptimeSec % 3600) ~/ 60;
    if (d > 0) return h > 0 ? '$d 天 $h 小时' : '$d 天';
    if (h > 0) return m > 0 ? '$h 小时 $m 分' : '$h 小时';
    return '$m 分钟';
  }
}

/// KB → 人类可读。df / /proc/meminfo 都是 KB 口径，直接喂给 [formatBytes] 会差 1024 倍。
String kbToText(int kb) => kb <= 0 ? '—' : formatBytes(kb * 1024);
