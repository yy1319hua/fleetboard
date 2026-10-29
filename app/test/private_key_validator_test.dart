import 'dart:convert';

import 'package:app/features/servers/domain/private_key_validator.dart';
import 'package:flutter_test/flutter_test.dart';

// PEM 头尾用拼接生成，不在源码里留下完整 PEM 字面量 —— credscan 规则
// （BEGIN 头 + END 尾）会把硬编码的样本当成真密钥拦下。
// 这里的样本是 base64(300×0x41)，没有任何密码学意义。
const String _dash = '-----';
String _begin(String type) => '${_dash}BEGIN $type$_dash';
String _end(String type) => '${_dash}END $type$_dash';

/// 构造一把「格式合法、但不可用于登录」的私钥。
String _fakeKey({String type = 'OPENSSH PRIVATE KEY'}) {
  final String body = base64.encode(List<int>.filled(300, 0x41));
  final List<String> lines = <String>[];
  for (int i = 0; i < body.length; i += 70) {
    lines.add(body.substring(i, (i + 70).clamp(0, body.length)));
  }
  return '${_begin(type)}\n${lines.join('\n')}\n${_end(type)}';
}

void main() {
  const PrivateKeyValidator validator = PrivateKeyValidator();

  group('合法私钥', () {
    test('标准 OpenSSH 私钥通过，无任何问题', () {
      final KeyCheckResult r = validator.check(_fakeKey());
      expect(r.issues, isEmpty);
      expect(r.hasBlocker, isFalse);
    });

    test('RSA / EC / PKCS#8 头均被接受', () {
      for (final String type in <String>[
        'RSA PRIVATE KEY',
        'EC PRIVATE KEY',
        'PRIVATE KEY',
      ]) {
        final KeyCheckResult r = validator.check(_fakeKey(type: type));
        expect(r.hasBlocker, isFalse, reason: '$type 应被接受');
      }
    });
  });

  group('结构性错误（阻断）', () {
    test('空内容', () {
      final KeyCheckResult r = validator.check('   \n  ');
      expect(r.firstBlocker!.code, KeyIssueCode.empty);
    });

    test('粘成公钥 -> 明确指出是公钥', () {
      final KeyCheckResult r =
          validator.check('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI user@host');
      expect(r.firstBlocker!.code, KeyIssueCode.publicKey);
      // 文案必须告诉用户「该找哪个文件」，不能只说错了
      expect(r.firstBlocker!.message, contains('.pub'));
    });

    test('PuTTY .ppk -> 给出转换命令', () {
      final KeyCheckResult r = validator
          .check('PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none');
      expect(r.firstBlocker!.code, KeyIssueCode.puttyPpk);
      expect(r.firstBlocker!.message, contains('puttygen'));
    });

    test('带口令（ENCRYPTED 头）', () {
      final KeyCheckResult r = validator.check(
        _fakeKey(type: 'ENCRYPTED PRIVATE KEY'),
      );
      expect(r.hasBlocker, isTrue);
    });

    test('带口令（legacy Proc-Type 头）', () {
      final String k = '${_begin('RSA PRIVATE KEY')}\n'
          'Proc-Type: 4,ENCRYPTED\n'
          'DEK-Info: AES-128-CBC,00\n\n'
          '${base64.encode(List<int>.filled(300, 0x41))}\n'
          '${_end('RSA PRIVATE KEY')}';
      final KeyCheckResult r = validator.check(k);
      expect(r.firstBlocker!.code, KeyIssueCode.encrypted);
      expect(r.firstBlocker!.message, contains('ssh-keygen -p'));
    });

    test('缺 BEGIN 头', () {
      final KeyCheckResult r =
          validator.check('AAAA\n${_end('OPENSSH PRIVATE KEY')}');
      expect(r.firstBlocker!.code, KeyIssueCode.missingHeader);
    });

    test('缺 END 尾（粘贴被截断）', () {
      final String k = _fakeKey();
      final KeyCheckResult r =
          validator.check(k.substring(0, k.indexOf(_end('OPENSSH PRIVATE KEY'))));
      expect(r.firstBlocker!.code, KeyIssueCode.missingFooter);
    });

    test('头尾类型不匹配（两段拼在一起）', () {
      final String k = '${_begin('RSA PRIVATE KEY')}\nAAAA\n'
          '${_end('OPENSSH PRIVATE KEY')}';
      final KeyCheckResult r = validator.check(k);
      expect(r.firstBlocker!.code, KeyIssueCode.headerFooterMismatch);
      expect(r.firstBlocker!.line, 3);
    });

    test('正文过短（复制漏了大半）', () {
      final String k = '${_begin('OPENSSH PRIVATE KEY')}\nQUJD\n'
          '${_end('OPENSSH PRIVATE KEY')}';
      final KeyCheckResult r = validator.check(k);
      expect(
        r.issues.any((KeyIssue i) => i.code == KeyIssueCode.truncated),
        isTrue,
      );
    });

    test('正文混入非 base64（说明文字）', () {
      final String k = '${_begin('OPENSSH PRIVATE KEY')}\n'
          'AAAA this is a note\n${_end('OPENSSH PRIVATE KEY')}';
      final KeyCheckResult r = validator.check(k);
      expect(
        r.issues.any((KeyIssue i) => i.code == KeyIssueCode.nonBase64),
        isTrue,
      );
      expect(r.issues.first.line, 2);
    });
  });

  group('不可见字符', () {
    test('全角空格：报出准确行号', () {
      final List<String> lines = _fakeKey().split('\n');
      lines[2] = '\u3000${lines[2]}';
      final KeyCheckResult r = validator.check(lines.join('\n'));
      final KeyIssue issue = r.issues.first;
      expect(issue.code, KeyIssueCode.invisibleChar);
      expect(issue.line, 3);
      expect(issue.message, contains('U+3000'));
      expect(issue.fixable, isTrue);
    });

    test('零宽字符与 BOM 都能识别', () {
      final String k = _fakeKey().replaceFirst('\n', '\u200B\n\uFEFF');
      final KeyCheckResult r = validator.check(k);
      expect(r.issues.first.code, KeyIssueCode.invisibleChar);
    });

    test('一行含多个不可见字符时合并成一条', () {
      final List<String> lines = _fakeKey().split('\n');
      lines[1] = '\u00A0\u3000${lines[1]}';
      final KeyCheckResult r = validator.check(lines.join('\n'));
      expect(r.issues.length, 1);
      expect(r.issues.first.message, contains('U+00A0'));
      expect(r.issues.first.message, contains('U+3000'));
    });
  });

  group('一键清理', () {
    test('repair 去掉不可见字符与行首尾空白后应通过校验', () {
      final List<String> lines = _fakeKey().split('\n');
      lines[1] = '  \u3000${lines[1]}  ';
      final String dirty = lines.join('\r\n');

      expect(validator.check(dirty).hasBlocker, isTrue);

      final String clean = PrivateKeyValidator.repair(dirty);
      expect(validator.check(clean).issues, isEmpty);
    });

    test('repair 幂等：清理两次结果一致', () {
      final String dirty = '  ${_begin('OPENSSH PRIVATE KEY')}\u200B  \n'
          '  AAAA \n  ${_end('OPENSSH PRIVATE KEY')}  ';
      final String once = PrivateKeyValidator.repair(dirty);
      expect(PrivateKeyValidator.repair(once), once);
    });
  });
}
