import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/apk_installer.dart';
import '../data/release_repository.dart';
import '../domain/release_info.dart';
import '../domain/sem_ver.dart';
import '../domain/update_config.dart';
import '../domain/update_error.dart';

/// 更新检查状态机（M9.5b）。
///
/// Idle -> Checking -> (UpToDate | Available) -> Downloading -> Verifying
///                                          -> Ready -> (安装) | Failure
sealed class UpdateState {
  const UpdateState();
}

/// 初始态：未做检查。
class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

/// 正在拉取 latest release 元信息。
class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

/// 已是最新版本；[current] 为当前安装版本号（不含 v 前缀）。
class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate(this.current);
  final String current;
}

/// 发现新版本；尚未下载。
class UpdateAvailable extends UpdateState {
  const UpdateAvailable({required this.release, required this.apkSize});
  final ReleaseInfo release;
  final int apkSize;
}

/// 下载中；[progress] 取值 0.0–1.0。
class UpdateDownloading extends UpdateState {
  const UpdateDownloading({required this.release, required this.progress});
  final ReleaseInfo release;
  final double progress;
}

/// 下载完成，正在做 SHA-256 校验（这一步失败即中止，不交付安装）。
class UpdateVerifying extends UpdateState {
  const UpdateVerifying(this.release);
  final ReleaseInfo release;
}

/// 校验通过，可安全安装；[apkPath] 为内部存储路径。
class UpdateReady extends UpdateState {
  const UpdateReady({required this.release, required this.apkPath});
  final ReleaseInfo release;
  final String apkPath;
}

/// 任一步骤失败；[message] 可直接展示给用户。
class UpdateFailure extends UpdateState {
  const UpdateFailure(this.message);
  final String message;
}

class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier(this._repo, this._installer) : super(const UpdateIdle());

  final ReleaseRepository _repo;
  final ApkInstaller _installer;

  /// 最近一次检查到的 Release，供下载/安装阶段复用（避免 UI 层回传）。
  ReleaseInfo? _release;

  /// 已下载并通过校验的 APK 路径（不等价于 state 中的 Ready 态，便于重复安装）。
  String? _verifiedPath;

  /// 拉取 latest release，与本地版本号做语义化比较。
  Future<void> check() async {
    state = const UpdateChecking();
    try {
      final info = await _packageInfo();

      final release = await _repo.fetchLatest();
      // 两个产物都要齐：缺 sums 文件时宁可不提示更新，也不让用户在没有校验的情况下装包。
      _repo.requireApkAsset(release);
      _repo.requireAsset(release, UpdateConfig.checksumsAssetName);
      _release = release;

      if (!SemVer.parse(release.tagName).isNewerThan(SemVer.parse(info.version))) {
        state = UpdateUpToDate(info.version);
        return;
      }
      final apk = _repo.requireApkAsset(release);
      state = UpdateAvailable(release: release, apkSize: apk.size);
    } catch (e) {
      state = UpdateFailure(_message(e));
    }
  }

  /// 下载 APK 并校验 SHA-256，通过后进入 [UpdateReady]。
  Future<void> download() async {
    final release = _release;
    if (release == null) return;

    state = UpdateDownloading(release: release, progress: 0);
    try {
      final dir = await _installer.updateDir();
      final apk = _repo.requireAsset(release, UpdateConfig.apkAssetName);
      final path = await _repo.downloadApk(apk, dir, onProgress: (p) {
        if (!mounted) return;
        state = UpdateDownloading(release: release, progress: p);
      });

      state = UpdateVerifying(release);
      await _repo.verifyApk(
        sumsAsset:
            _repo.requireAsset(release, UpdateConfig.checksumsAssetName),
        apkPath: path,
        apkName: apk.name,
      );

      _verifiedPath = path;
      state = UpdateReady(release: release, apkPath: path);
    } catch (e) {
      state = UpdateFailure(_message(e));
    }
  }

  /// 安装已校验的 APK。未获「未知来源」授权时先跳系统设置，返回 false 由 UI 提示重按。
  Future<bool> install() async {
    final path = _verifiedPath;
    if (path == null) return false;

    if (!await _installer.canInstallPackages()) {
      await _installer.openUnknownSourceSettings();
      return false;
    }
    try {
      await _installer.install(path);
      return true;
    } catch (e) {
      state = UpdateFailure(_message(e));
      return false;
    }
  }

  void reset() => state = const UpdateIdle();

  Future<PackageInfo> _packageInfo() => PackageInfo.fromPlatform();

  String _message(Object e) {
    if (e is UpdateError) return e.message;
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '网络超时，请稍后重试';
        case DioExceptionType.connectionError:
          return '网络连接失败，请检查网络';
        default:
          return '请求失败：${e.message ?? e.type.name}';
      }
    }
    return '未知错误：$e';
  }
}

/// 当前包的版本信息（版本号 / 构建号），关于页展示用。
final packageInfoProvider =
    FutureProvider<PackageInfo>((ref) => PackageInfo.fromPlatform());

final releaseRepositoryProvider =
    Provider<ReleaseRepository>((ref) => ReleaseRepository());

final apkInstallerProvider =
    Provider<ApkInstaller>((ref) => ApkInstaller());

final updateProvider =
    StateNotifierProvider<UpdateNotifier, UpdateState>((ref) {
  return UpdateNotifier(
    ref.watch(releaseRepositoryProvider),
    ref.watch(apkInstallerProvider),
  );
});
