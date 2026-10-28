import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/updater/domain/checksums.dart';
import 'package:app/features/updater/domain/update_error.dart';

void main() {
  // release.yml 的真实产出：在 flutter-apk 目录下执行
  // `sha256sum app-arm64-v8a-release.apk > sums-android.txt`
  const realSums = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      '  app-arm64-v8a-release.apk\n';
  const apkName = 'app-arm64-v8a-release.apk';

  test('解析 release.yml 真实产出的校验和文件', () {
    expect(
      requireChecksum(realSums, apkName),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  test('兼容带路径前缀、CRLF 与多余空行', () {
    const withPath =
        'aaa\r\n  \nE3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
        '  build/app/outputs/flutter-apk/$apkName\n';
    expect(
      requireChecksum(withPath, apkName),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  group('安全默认：任何异常都必须是拒绝，而非放行', () {
    test('找不到目标文件记录 -> 抛错', () {
      expect(
        () => requireChecksum(realSums, 'other.apk'),
        throwsA(isA<UpdateError>()),
      );
    });

    test('空文件 -> 抛错', () {
      expect(() => requireChecksum('', apkName), throwsA(isA<UpdateError>()));
      expect(() => requireChecksum('   \n\n', apkName),
          throwsA(isA<UpdateError>()));
    });

    test('摘要不是 64 位十六进制 -> 抛错（防止被改成短串绕过比对）', () {
      const short = 'e3b0c442  $apkName\n';
      expect(() => requireChecksum(short, apkName), throwsA(isA<UpdateError>()));
      const nonHex =
          'z3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85'
          '5  $apkName\n';
      expect(() => requireChecksum(nonHex, apkName), throwsA(isA<UpdateError>()));
    });

    test('无文件名字段 -> 抛错', () {
      expect(
        () => requireChecksum('e3b0c44298fc1c149afbf4c8996fb924\n', apkName),
        throwsA(isA<UpdateError>()),
      );
    });

    test('大小写差异不影响比对（统一转小写）', () {
      const upper = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
          '  $apkName\n';
      expect(requireChecksum(upper, apkName),
          requireChecksum(realSums, apkName));
    });
  });
}
