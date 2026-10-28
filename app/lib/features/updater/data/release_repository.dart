import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../domain/checksums.dart';
import '../domain/release_info.dart';
import '../domain/update_config.dart';
import '../domain/update_error.dart';

/// 更新源仓库：GitHub Release latest（拉/取元信息、下载 APK、核兑现）。
///
/// 与业务后端无关，故不使用鉴权 dio；GitHub 响应也不是 `{code,msg,data}` 信封，
/// 因此不走 EnvelopeInterceptor。
class ReleaseRepository {
  ReleaseRepository({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  /// GitHub 公共 API：匿名访问按 IP 限流（60 次/小时），手动检查更新足够。
  static Dio _createDio() {
    return Dio(
      BaseOptions(
        baseUrl: 'https://api.github.com',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: const <String, Object>{
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      ),
    );
  }

  /// 拉取最新 Release；仓库尚无 release 时抛 [UpdateError]。
  Future<ReleaseInfo> fetchLatest() async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '/repos/${UpdateConfig.owner}/${UpdateConfig.repo}/releases/latest',
    );
    final data = resp.data;
    if (data == null) {
      throw const UpdateError('未取到发布版本信息');
    }
    return ReleaseInfo.fromJson(data);
  }

  /// 取指定资产，缺失即抛错（宁愿报错也不让用户装到半截包）。
  ReleaseAsset requireAsset(ReleaseInfo release, String name) {
    for (final a in release.assets) {
      if (a.name == name) return a;
    }
    throw UpdateError('发布 ${release.tagName} 缺少产物 $name');
  }

  /// 下载 APK 到 `<dir>/<asset.name>`，[onProgress] 回传 0.0–1.0。
  Future<String> downloadApk(
    ReleaseAsset asset,
    String dir, {
    void Function(double progress)? onProgress,
  }) async {
    final savePath = '$dir/${_safeFileName(asset.name)}';
    await _dio.download(
      asset.downloadUrl,
      savePath,
      // GitHub 资源必须声明 octet-stream，否则返回的是资产元数据 JSON 而非二进制。
      options: Options(
        headers: const <String, Object>{'Accept': 'application/octet-stream'},
        receiveTimeout: const Duration(minutes: 10),
      ),
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );
    final file = File(savePath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw const UpdateError('APK 下载失败：文件为空');
    }
    return savePath;
  }

  /// 拉取校验和文件，并与本地 APK 的实际 SHA-256 逐字符比对（不匹配即抛错）。
  Future<void> verifyApk({
    required ReleaseAsset sumsAsset,
    required String apkPath,
    required String apkName,
  }) async {
    final resp = await _dio.get<String>(
      sumsAsset.downloadUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: const <String, Object>{'Accept': 'application/octet-stream'},
      ),
    );
    final text = resp.data;
    if (text == null || text.trim().isEmpty) {
      throw const UpdateError('校验和文件为空');
    }
    final expected = requireChecksum(text, apkName);
    final actual = await fileSha256(apkPath);
    if (expected != actual) {
      throw const UpdateError('安装包校验失败（SHA-256 不一致），已放弃安装');
    }
  }

  /// 流式计算文件 SHA-256（APK 约 9MB，避免整包读进内存）。
  Future<String> fileSha256(String path) async {
    final digest = await sha256.bind(File(path).openRead()).single;
    return digest.toString().toLowerCase();
  }

  /// 资产名落盘前净化：只保留文件名本体，拒绝含分隔符或 `..` 的名字。
  ///
  /// 资产名来自远端响应，虽由本仓库发布，仍不直接拼进路径 —— 否则一个含 `../`
  /// 的资产名就能把文件写到内部存储之外的位置。
  static String _safeFileName(String raw) {
    final name = raw.split(RegExp(r'[/\\]')).last.trim();
    if (name.isEmpty || name == '.' || name == '..') {
      throw UpdateError('发布产物名不合法：$raw');
    }
    return name;
  }
}
