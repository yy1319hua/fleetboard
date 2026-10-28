import 'update_error.dart';

/// 从 release.yml 产出的校验和文件中取出指定文件的 SHA-256。
///
/// 文件由 `sha256sum <apk>` 生成，单行格式：
/// `<64 位十六进制><空格><空格><文件名>`
/// 这里按「最后一个空白分隔字段」取文件名，兼容带路径前缀的写法。
String requireChecksum(String text, String fileName) {
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final name = parts.last.split('/').last;
    if (name != fileName) continue;
    final hex = parts.first.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
      throw const UpdateError('校验和文件格式异常：不是 64 位十六进制摘要');
    }
    return hex;
  }
  throw UpdateError('校验和文件中没有 $fileName 的记录');
}
