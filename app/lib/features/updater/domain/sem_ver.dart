/// 语义化版本号（major.minor.patch），用于版本号大小比较。
///
/// 为什么不能直接字符串比较：字典序里 `"v0.10.0" < "v0.9.0"` 成立，
/// 会把发布了 10 个 minor 的新版本判成旧版本，用户永远收不到更新。
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch);

  /// 解析 tag 或版本号。
  ///
  /// 容忍：前缀 `v` / `V`、构建后缀 `+12`、预发布后缀 `-rc.1`、缺位补 0（`0.3` -> 0.3.0）。
  factory SemVer.parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);
    final dash = s.indexOf('-');
    if (dash >= 0) s = s.substring(0, dash);
    final parts = s.split('.');

    int at(int i) => i < parts.length ? int.tryParse(parts[i].trim()) ?? 0 : 0;
    return SemVer(at(0), at(1), at(2));
  }

  final int major;
  final int minor;
  final int patch;

  bool isNewerThan(SemVer current) => compareTo(current) > 0;

  @override
  int compareTo(SemVer other) {
    var c = major.compareTo(other.major);
    if (c != 0) return c;
    c = minor.compareTo(other.minor);
    if (c != 0) return c;
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => '$major.$minor.$patch';

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}
