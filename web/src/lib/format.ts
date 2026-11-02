/** 时间/字节/数字格式化工具（统一出口，避免各处重复实现）。 */

/** 相对时间：<60s → "刚刚 / Ns 前"；<1h → "Nm 前"；<24h → "Nh 前"；否则日期。 */
export function formatRelative(iso: string | null | undefined): string {
  if (!iso) return "—";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "—";

  const diff = Date.now() - t;
  if (diff < 0) return "刚刚";
  const s = Math.floor(diff / 1000);
  if (s < 10) return "刚刚";
  if (s < 60) return `${s}s 前`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m 前`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h 前`;
  const d = Math.floor(h / 24);
  if (d < 30) return `${d}d 前`;
  return formatDate(iso);
}

export function formatDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** 日期 + 时分（日志/审计用）。 */
export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  const p = (n: number) => String(n).padStart(2, "0");
  return `${formatDate(iso)} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** 时:分:秒（日志流用，省日期）。 */
export function formatClock(iso: string | number | Date = new Date()): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "--:--:--";
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** 字节数 → 人类可读（1024 进制）。 */
export function formatBytes(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined || Number.isNaN(bytes)) return "—";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v >= 10 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

/** 保留 n 位小数的百分比字符串（null 显示 —）。 */
export function formatPct(v: number | null | undefined, digits = 1): string {
  if (v === null || v === undefined || Number.isNaN(v)) return "—";
  return `${v.toFixed(digits)}%`;
}

/** KB → 人类可读（df/内存总量都是 KB 口径）。 */
export function formatKB(kb: number | null | undefined): string {
  if (kb === null || kb === undefined || Number.isNaN(kb) || kb <= 0) return "—";
  return formatBytes(kb * 1024);
}

/** 运行秒数 → 「12 天 3 小时」这类粗粒度文案（精确到分没有意义）。 */
export function formatUptime(sec: number | null | undefined): string {
  if (sec === null || sec === undefined || Number.isNaN(sec) || sec <= 0) return "—";
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d > 0) return h > 0 ? `${d} 天 ${h} 小时` : `${d} 天`;
  if (h > 0) return m > 0 ? `${h} 小时 ${m} 分` : `${h} 小时`;
  return `${m} 分钟`;
}
