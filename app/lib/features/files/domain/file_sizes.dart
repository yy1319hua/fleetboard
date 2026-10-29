/// 字节数量级与传输速率的统一格式化。
///
/// 为什么单独抽出来：队列卡片、下载进度、编辑器上限提示三处都要显示大小，
/// 各写一遍必然出现 "4.0 MB" 与 "4096 KB" 混排，用户无法横向比较进度。
String formatBytes(int bytes) {
  if (bytes < 0) return '—';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '${value.toInt()}${units[unit]}';
  // 三位数不再保留小数：显示 "1024.0KB" 不如 "1.0MB" 好读。
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)}${units[unit]}';
}

/// 速率（字节/秒）。0 表示还没测出来，显示破折号而不是 "0B/s"。
String formatBandwidth(int bytesPerSecond) =>
    bytesPerSecond <= 0 ? '—' : '${formatBytes(bytesPerSecond)}/s';

/// 百分比（0~1 → "37%"）。
String formatPercent(double ratio) {
  final pct = (ratio.isNaN ? 0.0 : ratio).clamp(0.0, 1.0) * 100;
  return '${pct.round()}%';
}
