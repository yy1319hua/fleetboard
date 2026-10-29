/// 单个容器的资源占用快照（对齐后端 `internal/docker` 的 `Stats`）。
///
/// 为什么所有数值都是字符串：这些值直接来自 `docker stats --format '{{json .}}'`，
/// 形如 `"0.15%"`、`"12.3MiB / 1GiB"`。在后端转成数字会丢失单位与「/ 上限」的
/// 表达（内存是 "用量 / 上限"），前端再拼回去既麻烦又容易算错。原样透传最忠实。
///
/// 为什么手写 [fromJson] 而不用 freezed：这是一个纯只读 DTO，没有 copyWith、
/// 没有相等性需求，用 freezed 只会多一个生成文件与一次 build_runner，
/// 而生成物不入库（见 app/.gitignore），每个新环境还要多跑一步才能编译。
class ContainerStat {
  const ContainerStat({
    required this.container,
    required this.name,
    required this.cpuPerc,
    required this.memUsage,
    required this.memPerc,
    required this.netIo,
    required this.blockIo,
    required this.pids,
  });

  /// 12 位短容器 ID（`docker stats` 给的就是短 ID，不是 64 位全 ID）。
  final String container;
  final String name;

  /// 形如 `"0.15%"`。
  final String cpuPerc;

  /// 形如 `"12.3MiB / 1GiB"`（用量 / 上限）。
  final String memUsage;

  /// 形如 `"1.23%"`。
  final String memPerc;

  final String netIo;
  final String blockIo;
  final String pids;

  factory ContainerStat.fromJson(Map<String, dynamic> json) => ContainerStat(
        container: (json['container'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        cpuPerc: (json['cpu_perc'] as String?) ?? '',
        memUsage: (json['mem_usage'] as String?) ?? '',
        memPerc: (json['mem_perc'] as String?) ?? '',
        netIo: (json['net_io'] as String?) ?? '',
        blockIo: (json['block_io'] as String?) ?? '',
        pids: (json['pids'] as String?) ?? '',
      );
}
