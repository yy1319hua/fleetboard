import 'package:app/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// M10.2：客户端内置服务器地址的规范化与校验。
///
/// 这些断言同时起"编译期常量守卫"作用：若 `String.fromEnvironment` 被误写到
/// 非 const 上下文（AOT 下会静默取空值），相关分支会先炸出来。
///
/// 注意：仓库内不保存真实服务器地址（credscan 规则禁止内网域名入库），
/// 因此本测试只用 example.com / localhost 这类保留示例域名。
void main() {
  group('AppConfig.defaultBaseUrl', () {
    test('未注入 dart-define 时回退内置常量（内置常量故意为空）', () {
      // 测试进程未传 --dart-define，注入值为空。
      expect(AppConfig.injectedBaseUrl, isEmpty);
      expect(AppConfig.defaultBaseUrl, AppConfig.fallbackBaseUrl);
      expect(AppConfig.fallbackBaseUrl, isEmpty);
    });

    test('未配置时 hasDefaultBaseUrl 为 false', () {
      expect(AppConfig.hasDefaultBaseUrl, isFalse);
    });

    test('未配置时 defaultHost 不产生有效主机名', () {
      expect(AppConfig.defaultHost, isEmpty);
    });
  });

  group('AppConfig.normalize', () {
    test('去掉尾部斜杠', () {
      expect(AppConfig.normalize('https://a.example.com/'),
          'https://a.example.com');
    });

    test('去掉多个尾部斜杠', () {
      expect(AppConfig.normalize('https://a.example.com///'),
          'https://a.example.com');
    });

    test('去首尾空白', () {
      expect(AppConfig.normalize('  https://a.example.com  '),
          'https://a.example.com');
    });

    test('不擅自补 https（内网 http 部署必须原样保留）', () {
      expect(AppConfig.normalize('http://localhost:8080'),
          'http://localhost:8080');
    });

    test('空串保持空串', () {
      expect(AppConfig.normalize('   '), '');
    });

    test('保留路径前缀', () {
      expect(AppConfig.normalize('https://a.example.com/fb/'),
          'https://a.example.com/fb');
    });
  });

  group('AppConfig.looksValid', () {
    test('接受 http/https 完整地址', () {
      expect(AppConfig.looksValid('https://a.example.com'), isTrue);
      expect(AppConfig.looksValid('http://localhost:8080'), isTrue);
      expect(AppConfig.looksValid('https://a.example.com/'), isTrue);
    });

    test('拒绝缺 scheme 的裸域名', () {
      expect(AppConfig.looksValid('a.example.com'), isFalse);
    });

    test('拒绝空值与纯空白', () {
      expect(AppConfig.looksValid(''), isFalse);
      expect(AppConfig.looksValid('   '), isFalse);
    });

    test('拒绝非 http(s) 协议', () {
      expect(AppConfig.looksValid('ftp://a.example.com'), isFalse);
    });
  });

  group('AppConfig.hostOf', () {
    test('取 host 并剥离端口以外的部分', () {
      expect(AppConfig.hostOf('https://a.example.com'), 'a.example.com');
      expect(AppConfig.hostOf('http://localhost:8080'), 'localhost');
    });

    test('解析失败时原样返回', () {
      expect(AppConfig.hostOf('not a url'), 'not a url');
    });

    test('空值返回空串', () {
      expect(AppConfig.hostOf(''), '');
    });
  });
}
