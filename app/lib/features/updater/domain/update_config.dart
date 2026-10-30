/// 自分发更新源：写死仓库坐标，App 侧不再引入额外配置项。
///
/// APK 与校验和文件由 release.yml 在打 tag 时自动上传到 GitHub Release，
/// App 只消费「latest release + 同名资产」这一约定。
class UpdateConfig {
  const UpdateConfig._();

  /// GitHub 仓库 owner / repo，对应 https://github.com/yy1319hua/fleetboard
  static const String owner = 'yy1319hua';
  static const String repo = 'fleetboard';

  /// release.yml android job 上传的 arm64 APK 文件名。
  ///
  /// v0.4.4 起按产品名重命名为 fleetboard-*，此前是 Flutter 默认的
  /// app-arm64-v8a-release.apk。改名直接导致写死旧名的客户端（≤v0.4.3）
  /// 在「检查更新」时报「缺少产物」而完全无法自更新——所以匹配不再只认
  /// 一个名字：精确名找不到时按 ABI 后缀兜底（见 ReleaseRepository.requireApkAsset）。
  static const String apkAssetName = 'fleetboard-arm64-v8a-release.apk';

  /// ABI 后缀。资产名前缀（fleetboard- / app-）再调整也能认出来。
  static const String apkAbiSuffix = '-arm64-v8a-release.apk';

  /// 与 APK 同批发出的 SHA-256 校验和文件（`sha256sum` 默认输出格式）。
  static const String checksumsAssetName = 'sums-android.txt';
}
