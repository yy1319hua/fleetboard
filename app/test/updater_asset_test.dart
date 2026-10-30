import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/updater/data/release_repository.dart';
import 'package:app/features/updater/domain/release_info.dart';
import 'package:app/features/updater/domain/update_error.dart';

ReleaseAsset _asset(String name) => ReleaseAsset(
      name: name,
      downloadUrl: 'https://example.com/$name',
      size: 1024,
    );

ReleaseInfo _release(List<ReleaseAsset> assets) => ReleaseInfo(
      tagName: 'v0.4.5',
      htmlUrl: 'https://github.com/yy1319hua/fleetboard/releases/tag/v0.4.5',
      name: 'v0.4.5',
      assets: assets,
    );

/// APK 资产查找的三条路径。
///
/// 背景：v0.4.4 把产物从 Flutter 默认的 app-arm64-v8a-release.apk 改名为
/// fleetboard-arm64-v8a-release.apk，而客户端写死了旧名，于是设备上 v0.4.3
/// 的「检查更新」直接报「发布 v0.4.4 缺少产物 app-arm64-v8a-release.apk」，
/// 整条自更新链路断掉。查找逻辑因此不再只认一个名字。
void main() {
  final repo = ReleaseRepository();

  test('精确名命中 fleetboard-*', () {
    final apk = repo.requireApkAsset(
      _release(<ReleaseAsset>[_asset('fleetboard-arm64-v8a-release.apk')]),
    );
    expect(apk.name, 'fleetboard-arm64-v8a-release.apk');
  });

  test('只有旧名 app-* 时按 ABI 后缀兜底', () {
    final apk = repo.requireApkAsset(
      _release(<ReleaseAsset>[_asset('app-arm64-v8a-release.apk')]),
    );
    expect(apk.name, 'app-arm64-v8a-release.apk');
  });

  test('多资产中不会被 tar.gz 或校验和文件干扰', () {
    final apk = repo.requireApkAsset(_release(<ReleaseAsset>[
      _asset('sums.txt'),
      _asset('sums-android.txt'),
      _asset('fleetboard-v0.4.5-linux-amd64.tar.gz'),
      _asset('fleetboard-arm64-v8a-release.apk'),
    ]));
    expect(apk.name, 'fleetboard-arm64-v8a-release.apk');
  });

  test('后缀兜底也不会误取 x86_64 APK（只认 arm64-v8a）', () {
    final apk = repo.requireApkAsset(_release(<ReleaseAsset>[
      _asset('fleetboard-x86_64-release.apk'),
      _asset('fleetboard-arm64-v8a-release.apk'),
    ]));
    expect(apk.name, 'fleetboard-arm64-v8a-release.apk');
  });

  test('找不到时把实际资产名列进错误信息', () {
    expect(
      () => repo.requireApkAsset(
        _release(<ReleaseAsset>[_asset('sums.txt')]),
      ),
      throwsA(
        isA<UpdateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('缺少 arm64 安装包'), contains('sums.txt')),
        ),
      ),
    );
  });

  test('资产为空时明确说明，而不是只报缺某个文件名', () {
    expect(
      () => repo.requireApkAsset(_release(const <ReleaseAsset>[])),
      throwsA(
        isA<UpdateError>().having(
          (e) => e.message,
          'message',
          contains('没有任何资产'),
        ),
      ),
    );
  });
}
