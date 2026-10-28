import 'package:flutter/services.dart';

import '../domain/update_error.dart';

/// APK 安装通道（原生侧实现见 MainActivity.kt）。
///
/// 为什么要走 MethodChannel 而不是纯 Dart 包：Android 7.0+ 禁止跨应用传递 `file://` URI，
/// 必须经 FileProvider 临时授权后才能交给系统安装器 —— 这一步只能在原生侧完成。
class ApkInstaller {
  ApkInstaller({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('io.github.yy1319hua.app/installer');

  final MethodChannel _channel;

  /// APK 下载目录（内部存储 filesDir/updates）。
  Future<String> updateDir() async {
    final dir = await _channel.invokeMethod<String>('getUpdateDir');
    if (dir == null || dir.isEmpty) {
      throw const UpdateError('无法获取 APK 存放目录');
    }
    return dir;
  }

  /// 是否已获得「安装未知应用」授权（Android 8.0 之前无按包名查询能力，按已授权处理）。
  Future<bool> canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳转系统「允许此来源的应用」设置页。
  Future<void> openUnknownSourceSettings() =>
      _channel.invokeMethod<void>('openUnknownSourceSettings');

  /// 唤起系统安装器安装已校验的 APK。
  Future<void> install(String apkPath) async {
    try {
      await _channel.invokeMethod<void>(
        'installApk',
        <String, Object?>{'path': apkPath},
      );
    } on PlatformException catch (e) {
      throw UpdateError(e.message ?? '调用安装器失败');
    } on MissingPluginException {
      throw const UpdateError('当前不是 Android 运行环境，无法安装 APK');
    }
  }
}
