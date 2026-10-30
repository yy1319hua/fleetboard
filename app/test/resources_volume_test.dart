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

  _cleanupResultSuite();
}

/// 清理结果的「三态」必须由后端字段驱动，不能用缺省值猜：
/// 旧后端不返回 deleted_count 时，绝不能显示「没有可清理的资源」。
void _cleanupResultSuite() {
  group('DockerPruneOutcome 三态', () {
    test('后端报告删了 1 个卷', () {
      final r = DockerPruneOutcome.fromJson(<String, dynamic>{
        'target': 'volumes',
        'reclaimed': '85.94MB',
        'deleted_items': <String>['dockdeck_dockdeck-hub-data'],
        'deleted_count': 1,
        'nothing_deleted': false,
      });
      expect(r.reported, isTrue);
      expect(r.actualDeletedCount, 1);
      expect(r.deletedNothing, isFalse);
      expect(r.failed, isFalse);
    });

    test('后端报告没有可删项', () {
      final r = DockerPruneOutcome.fromJson(<String, dynamic>{
        'target': 'volumes',
        'reclaimed': '0B',
        'deleted_items': <String>[],
        'deleted_count': 0,
        'nothing_deleted': true,
      });
      expect(r.reported, isTrue);
      expect(r.deletedNothing, isTrue);
    });

    test('旧后端未报字段：不得判定为「没有可清理」', () {
      final r = DockerPruneOutcome.fromJson(<String, dynamic>{
        'target': 'images',
        'reclaimed': '0B',
      });
      expect(r.reported, isFalse);
      expect(r.deletedNothing, isFalse);
    });

    test('单项失败：错误原文保留', () {
      final r = DockerPruneOutcome.fromJson(<String, dynamic>{
        'target': 'volumes',
        'error': '卷仍被容器占用：dockdeck-hub',
      });
      expect(r.failed, isTrue);
      expect(r.deletedNothing, isFalse);
      expect(r.error, contains('dockdeck-hub'));
    });
  });

  group('容量换算', () {
    test('docker 容量串转字节', () {
      expect(parseDockerSizeBytes('85.94MB'), (85.94 * 1024 * 1024).round());
      expect(parseDockerSizeBytes('0B'), 0);
      expect(parseDockerSizeBytes('1.2GB'), (1.2 * 1024 * 1024 * 1024).round());
      expect(parseDockerSizeBytes('512KB'), 512 * 1024);
    });

    test('无法识别的串返回 null，不编造', () {
      expect(parseDockerSizeBytes(''), isNull);
      expect(parseDockerSizeBytes('—'), isNull);
      expect(parseDockerSizeBytes('800MB (66%)'), isNull);
    });

    test('字节格式化去掉尾零', () {
      expect(formatSizeBytes(0), '0B');
      expect(formatSizeBytes(85 * 1024 * 1024), '85MB');
      expect(formatSizeBytes((85.94 * 1024 * 1024).round()), '85.94MB');
      expect(formatSizeBytes(1024 * 1024 * 1024), '1GB');
    });
  });

  group('DockerVolumePreview 解析', () {
    test('卷名与 compose 项目都要带出来', () {
      final p = DockerVolumePreview.fromJson(<String, dynamic>{
        'volumes': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'dockdeck_dockdeck-hub-data',
            'compose_project': 'dockdeck',
          },
        ],
        'count': 1,
        'total_count': 1,
        'in_use_count': 0,
        'reclaimable': '85.94MB (100%)',
      });
      expect(p.volumes.single.name, 'dockdeck_dockdeck-hub-data');
      expect(p.volumes.single.composeProject, 'dockdeck');
      expect(p.totalCount, 1);
      expect(p.inUseCount, 0);
    });

    test('缺字段时按空处理，不崩', () {
      final p = DockerVolumePreview.fromJson(<String, dynamic>{});
      expect(p.volumes, isEmpty);
      expect(p.totalCount, 0);
    });
  });
}
