import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/updater/domain/sem_ver.dart';

void main() {
  group('SemVer.parse', () {
    test('解析标准三段版本号', () {
      final v = SemVer.parse('1.2.3');
      expect(v.major, 1);
      expect(v.minor, 2);
      expect(v.patch, 3);
    });

    test('容忍 v 前缀、构建后缀与预发布后缀', () {
      expect(SemVer.parse('v0.3.0'), const SemVer(0, 3, 0));
      expect(SemVer.parse('V2.0.1+12'), const SemVer(2, 0, 1));
      expect(SemVer.parse('v1.4.0-rc.1'), const SemVer(1, 4, 0));
    });

    test('缺位补 0，非法段按 0 处理', () {
      expect(SemVer.parse('0.3'), const SemVer(0, 3, 0));
      expect(SemVer.parse('v1'), const SemVer(1, 0, 0));
      expect(SemVer.parse('v1.x.2'), const SemVer(1, 0, 2));
    });
  });

  group('isNewerThan', () {
    test('关键回归：v0.10.0 必须新于 v0.9.0（字符串比较会判反）', () {
      // 这是本类存在的唯一理由：字典序下 "v0.10.0" < "v0.9.0"，
      // 若改用字符串比较，发布到第 10 个 minor 后用户将永远收不到更新。
      expect(SemVer.parse('v0.10.0').isNewerThan(SemVer.parse('v0.9.0')), isTrue);
      expect(SemVer.parse('v0.9.0').isNewerThan(SemVer.parse('v0.10.0')), isFalse);
    });

    test('逐级比较：major > minor > patch', () {
      expect(SemVer.parse('1.0.0').isNewerThan(SemVer.parse('0.99.99')), isTrue);
      expect(SemVer.parse('0.2.0').isNewerThan(SemVer.parse('0.1.9')), isTrue);
      expect(SemVer.parse('0.2.1').isNewerThan(SemVer.parse('0.2.0')), isTrue);
    });

    test('相同版本不算更新', () {
      expect(SemVer.parse('v0.2.0').isNewerThan(SemVer.parse('0.2.0')), isFalse);
      expect(SemVer.parse('v0.2.0+7').isNewerThan(SemVer.parse('0.2.0+3')),
          isFalse);
    });

    test('比较不受构建号影响（同版本不同构建号视为同一版本）', () {
      expect(SemVer.parse('1.0.0+1') == SemVer.parse('v1.0.0+99'), isTrue);
    });
  });

  group('排序与相等', () {
    test('列表按语义排序正确', () {
      final list = <SemVer>[
        SemVer.parse('v0.10.0'),
        SemVer.parse('v0.2.0'),
        SemVer.parse('v0.9.0'),
        SemVer.parse('v1.0.0'),
      ]..sort();
      expect(list.map((e) => e.toString()).toList(),
          <String>['0.2.0', '0.9.0', '0.10.0', '1.0.0']);
    });

    test('相等与 hashCode 一致', () {
      const a = SemVer(1, 2, 3);
      final b = SemVer.parse('v1.2.3');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
