import 'package:app/features/resources/domain/docker_resource.dart';
import 'package:flutter_test/flutter_test.dart';

/// 卷名校验必须与后端 `docker.ValidateVolumeName` 同规则：
/// 后端是防命令注入的硬约束（卷名会拼进 `docker volume rm`），
/// 客户端提前拦只是为了给出可读提示，松一格就会变成「点了才 400」。
void main() {
  group('validateVolumeName', () {
    test('合法卷名通过', () {
      for (final name in <String>[
        'dockdeck_dockdeck-hub-data',
        'a',
        'vol.1',
        '9lives',
        'a' * 255,
      ]) {
        expect(validateVolumeName(name), isNull, reason: name);
      }
    });

    test('非法卷名被拦下', () {
      for (final name in <String>[
        '',
        '   ',
        '-leading',
        '.hidden',
        'has space',
        'a; rm -rf /',
        r'a$(id)',
        'a`id`',
        '路径/斜杠',
        'a' * 256,
      ]) {
        expect(validateVolumeName(name), isNotNull, reason: name);
      }
    });
  });

  group('DockerDiskUsage', () {
    test('reclaimableSize 去掉百分比', () {
      const row = DockerDiskUsage(
        type: 'Images',
        totalCount: '12',
        active: '3',
        size: '1.2GB',
        reclaimable: '800MB (66%)',
      );
      expect(row.reclaimableSize, '800MB');
    });

    test('没有百分比时原样返回', () {
      const row = DockerDiskUsage(
        type: 'Build Cache',
        totalCount: '0',
        active: '0',
        size: '0B',
        reclaimable: '0B',
      );
      expect(row.reclaimableSize, '0B');
    });
  });

  group('DockerPruneOutcome', () {
    test('目标名映射成中文', () {
      expect(
        const DockerPruneOutcome(target: 'images', output: '', reclaimed: '')
            .label,
        '悬空镜像',
      );
      expect(
        const DockerPruneOutcome(target: 'volumes', output: '', reclaimed: '')
            .label,
        '未使用卷',
      );
      expect(
        const DockerPruneOutcome(
          target: 'build_cache',
          output: '',
          reclaimed: '',
        ).label,
        '构建缓存',
      );
    });

    test('未知目标原样展示，不猜', () {
      expect(
        const DockerPruneOutcome(target: 'containers', output: '', reclaimed: '')
            .label,
        'containers',
      );
    });
  });
}
