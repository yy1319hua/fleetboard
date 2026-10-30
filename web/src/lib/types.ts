/** 与后端 model 对齐的前端类型。字段名保持后端 json 标签，不做驼峰转换。 */

export type ConnectionStatus = "online" | "offline" | "unknown";

export interface Server {
  id: number;
  name: string;
  host: string;
  port: number;
  ssh_user: string;
  auth_method: "password" | "key";
  connection_status: ConnectionStatus;
  last_heartbeat: string | null;
  tags: string;
  created_at: string;
}

export interface Container {
  id: string;
  name: string;
  image: string;
  state: string;
  status: string;
  created_at: string;
  ports: string;
}

export interface ServerMetric {
  id: number;
  server_id: number;
  ts: string;
  cpu_pct: number;
  mem_pct: number;
  disk_pct: number;
  load1: number;
  net_in_kbps: number;
  net_out_kbps: number;
}

export interface AlertRule {
  id: number;
  server_id: number | null;
  metric: "cpu_pct" | "mem_pct" | "disk_pct" | "offline";
  operator: ">" | "<" | "=";
  threshold: number;
  severity: "info" | "warn" | "critical";
  enabled: boolean;
  notify_channels: string;
  created_at: string;
}

export interface AlertEvent {
  id: number;
  server_id: number | null;
  rule_id: number | null;
  severity: "info" | "warn" | "critical";
  title: string;
  message: string;
  is_read: boolean;
  created_at: string;
}

export interface FileEntry {
  name: string;
  path: string;
  dir: boolean;
  size: number;
  mode: string;
  uid: number;
  gid: number;
  mod_time: string;
}

export interface ComposeFile {
  name: string;
  path: string;
  size: number;
  mod_time: string;
}

export interface ComposeList {
  roots: string[];
  dir: string;
  dirs: string[];
  files: ComposeFile[];
  skipped: number;
}

export interface TokenPair {
  access_token: string;
  refresh_token: string;
  expires_in: number;
}

export interface ImageItem {
  id: string;
  repository: string;
  tag: string;
  size: string;
  created_since: string;
}

export interface NetworkItem {
  id: string;
  name: string;
  driver: string;
  scope: string;
}

export interface VolumeItem {
  name: string;
  driver: string;
  mountpoint: string;
}

/** docker system df 的一行（后端 docker.DiskUsage）。 */
export interface DockerDiskUsage {
  type: string;
  total_count: string;
  active: string;
  size: string;
  reclaimable: string;
}

/** 单个清理目标的回收结果（后端 docker.PruneResult）。 */
export interface PruneOutcome {
  target: string;
  output: string;
  reclaimed: string;
  /** 实际删除的条目（卷名 / 镜像引用 / 缓存 ID）。缺省 = 后端未报告，不是 0。 */
  deleted_items?: string[];
  deleted_count?: number;
  /** true = 本次没有可删项，与「删了但回收 0B」严格区分。 */
  nothing_deleted?: boolean;
  /** 该项失败原因；空/缺省表示成功。原样展示，不改写。 */
  error?: string;
}

/** 未使用卷预览（GET /api/servers/:id/docker/unused-volumes）。 */
export interface UnusedVolumesPreview {
  /** 将被 `docker volume prune -a -f` 删除的卷（无任何容器引用，含命名卷）。 */
  volumes: Array<{ name: string; compose_project?: string }>;
  count: number;
  /** 卷总数（含被引用的），用于解释「为什么一个都删不掉」。 */
  total_count: number;
  in_use_count: number;
  reclaimable: string;
  prune_command: string;
  snapshot_at: string;
}

export interface ContainerStat {
  container: string;
  name: string;
  cpu_perc: string;
  mem_usage: string;
  mem_perc: string;
  net_io: string;
  block_io: string;
  pids: string;
}

export interface OperationLog {
  id: number;
  user_id: number;
  server_id: number | null;
  action: string;
  detail: string;
  result: string;
  created_at: string;
}
