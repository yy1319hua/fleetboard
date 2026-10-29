import 'dart:convert';

/// 私钥校验结果的严重程度。
///
/// [blocker] 阻断保存；[warning] 提示但仍放行。
enum KeyIssueSeverity { blocker, warning }

/// 私钥校验问题码。文案与码分离，便于测试断言不依赖具体措辞。
enum KeyIssueCode {
  empty,
  puttyPpk,
  publicKey,
  missingHeader,
  missingFooter,
  headerFooterMismatch,
  encrypted,
  unsupportedType,
  invisibleChar,
  nonBase64,
  truncated,
}

/// 单条校验问题。
class KeyIssue {
  const KeyIssue({
    required this.code,
    required this.severity,
    required this.message,
    this.line,
    this.fixable = false,
  });

  final KeyIssueCode code;
  final KeyIssueSeverity severity;

  /// 面向用户的中文说明，必须包含「怎么改」而不只是「哪里错」。
  final String message;

  /// 1-based 行号（相对粘贴文本）。归一化行尾不改变行数，故可直接展示。
  final int? line;

  /// 是否可被「一键清理」自动修复。
  final bool fixable;
}

/// 校验结果。
class KeyCheckResult {
  const KeyCheckResult({required this.issues, required this.normalized});

  const KeyCheckResult.ok()
      : issues = const <KeyIssue>[],
        normalized = '';

  final List<KeyIssue> issues;

  /// 清理后的文本（去不可见字符、去每行首尾空白、统一行尾）。
  final String normalized;

  bool get hasBlocker =>
      issues.any((KeyIssue i) => i.severity == KeyIssueSeverity.blocker);

  bool get hasFixable => issues.any((KeyIssue i) => i.fixable);

  /// 第一条阻断项，供 UI 只显示一条主错误。
  KeyIssue? get firstBlocker {
    for (final KeyIssue issue in issues) {
      if (issue.severity == KeyIssueSeverity.blocker) return issue;
    }
    return null;
  }
}

/// SSH 私钥格式预检。
///
/// 只做格式层面判断（是否像一把可用的 OpenSSH 私钥），**不做密码学校验**，
/// 也不联网。目的是在用户点「测试连接」之前就把「粘错了东西」拦下来 ——
/// 手机上粘多行私钥出错率高，等 SSH 报 "invalid format" 时用户不知道错在哪一行。
class PrivateKeyValidator {
  const PrivateKeyValidator();

  static const List<String> _allowedTypes = <String>[
    'OPENSSH PRIVATE KEY',
    'RSA PRIVATE KEY',
    'EC PRIVATE KEY',
    'DSA PRIVATE KEY',
    'PRIVATE KEY', // PKCS#8
  ];

  /// authorized_keys 的前缀，用来识别「粘成公钥」。
  static const List<String> _publicKeyPrefixes = <String>[
    'ssh-rsa ',
    'ssh-ed25519 ',
    'ssh-dss ',
    'ecdsa-sha2-',
    'sk-ssh-ed25519@',
    'sk-ecdsa-sha2-',
  ];

  static const Map<int, String> _invisibleNames = <int, String>{
    0x00A0: '不换行空格 NBSP',
    0x3000: '全角空格',
    0x200B: '零宽空格',
    0x200C: '零宽非连接符',
    0x200D: '零宽连接符',
    0xFEFF: 'BOM / 零宽不换行空格',
    0x00AD: '软连字符',
    0x2028: '行分隔符',
    0x2029: '段分隔符',
  };

  static final RegExp _headerRe = RegExp(r'^-----BEGIN ([A-Z0-9 ]+)-----$');
  static final RegExp _footerRe = RegExp(r'^-----END ([A-Z0-9 ]+)-----$');
  static final RegExp _base64Re = RegExp(r'^[A-Za-z0-9+/=]+$');

  KeyCheckResult check(String raw) {
    // 只统一行尾，行数不变，后续行号可直接给用户看。
    final String text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.trim().isEmpty) {
      return const KeyCheckResult(
        issues: <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.empty,
            severity: KeyIssueSeverity.blocker,
            message: '请粘贴 SSH 私钥内容',
          ),
        ],
        normalized: '',
      );
    }

    final String normalized = repair(raw);
    final List<String> lines = text.split('\n');

    // 结构级判定：命中即早返回，避免一次刷出十几条互相矛盾的红字。
    if (text.contains('PuTTY-User-Key-File')) {
      return KeyCheckResult(
        issues: const <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.puttyPpk,
            severity: KeyIssueSeverity.blocker,
            message: '这是 PuTTY 的 .ppk 格式，服务器只接受 OpenSSH 私钥。'
                '请先转换：puttygen key.ppk -O private-openssh -o id_rsa',
          ),
        ],
        normalized: normalized,
      );
    }

    final String firstLine = lines
        .map((String l) => l.trim())
        .firstWhere((String l) => l.isNotEmpty, orElse: () => '');
    if (_publicKeyPrefixes.any(firstLine.startsWith)) {
      return KeyCheckResult(
        issues: const <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.publicKey,
            severity: KeyIssueSeverity.blocker,
            message: '粘贴的是公钥（以 ssh-rsa / ssh-ed25519 开头），登录需要私钥。'
                '私钥文件通常是 id_rsa 或 id_ed25519，带 .pub 后缀的才是公钥。',
          ),
        ],
        normalized: normalized,
      );
    }

    // 不可见字符必须在结构判定之后、内容判定之前处理：
    // 它会污染后面的所有正则与 base64 解码，先清掉才能给出有意义的错误。
    final List<KeyIssue> charIssues = <KeyIssue>[];
    for (int i = 0; i < lines.length; i++) {
      final Set<String> found = <String>{};
      for (final int rune in lines[i].runes) {
        final String? name = _invisibleNames[rune];
        if (name == null) continue;
        final String code =
            'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}';
        found.add('$code（$name）');
      }
      if (found.isEmpty) continue;
      charIssues.add(
        KeyIssue(
          code: KeyIssueCode.invisibleChar,
          severity: KeyIssueSeverity.blocker,
          line: i + 1,
          message: '第 ${i + 1} 行含 ${found.join('、')}',
          fixable: true,
        ),
      );
    }
    if (charIssues.isNotEmpty) {
      return KeyCheckResult(issues: charIssues, normalized: normalized);
    }

    final int headerIndex = lines.indexWhere(
      (String l) => _headerRe.hasMatch(l.trim()),
    );
    if (headerIndex < 0) {
      return KeyCheckResult(
        issues: const <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.missingHeader,
            severity: KeyIssueSeverity.blocker,
            message: '缺少 BEGIN 开头行（以五个短横线加 BEGIN 起头）。'
                '常见原因：只复制了中间的 base64 部分，或首行被编辑器截断。',
          ),
        ],
        normalized: normalized,
      );
    }

    final String headerType =
        _headerRe.firstMatch(lines[headerIndex].trim())!.group(1)!;
    if (!_allowedTypes.contains(headerType)) {
      return KeyCheckResult(
        issues: <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.unsupportedType,
            severity: KeyIssueSeverity.blocker,
            message: '不支持的私钥类型「$headerType」。'
                '支持：${_allowedTypes.join(' / ')}',
          ),
        ],
        normalized: normalized,
      );
    }

    final int footerIndex = lines.indexWhere(
      (String l) => _footerRe.hasMatch(l.trim()),
      headerIndex + 1,
    );
    if (footerIndex < 0) {
      return KeyCheckResult(
        issues: <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.missingFooter,
            severity: KeyIssueSeverity.blocker,
            message: '缺少结尾的 -----END $headerType-----，私钥内容不完整（可能粘贴被截断）。',
          ),
        ],
        normalized: normalized,
      );
    }

    final String footerType =
        _footerRe.firstMatch(lines[footerIndex].trim())!.group(1)!;
    if (footerType != headerType) {
      return KeyCheckResult(
        issues: <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.headerFooterMismatch,
            severity: KeyIssueSeverity.blocker,
            line: footerIndex + 1,
            message: '第 ${footerIndex + 1} 行的 END 标记（$footerType）与开头的 BEGIN'
                '（$headerType）不匹配，可能是两段内容被拼在一起了。',
          ),
        ],
        normalized: normalized,
      );
    }

    // 加密私钥：只查 BEGIN 头行与 legacy 头，不全文 contains ——
    // base64 字符集包含全部大写字母，"ENCRYPTED" 可能在正文里偶然出现。
    final bool legacyEncrypted = lines.any((String l) =>
            l.startsWith('Proc-Type:') && l.contains('ENCRYPTED')) ||
        lines.any((String l) => l.startsWith('DEK-Info:'));
    if (lines[headerIndex].contains('ENCRYPTED') || legacyEncrypted) {
      return KeyCheckResult(
        issues: const <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.encrypted,
            severity: KeyIssueSeverity.blocker,
            message: '这把私钥带密码保护，服务器无法解密。'
                '请先去除口令：ssh-keygen -p -f id_ed25519 -N ""',
          ),
        ],
        normalized: normalized,
      );
    }

    // 内容级判定：允许累积多条，用户可一次看完。
    final List<KeyIssue> issues = <KeyIssue>[];
    final List<String> body = <String>[];
    for (int i = headerIndex + 1; i < footerIndex; i++) {
      final String line = lines[i];
      if (line.trim().isEmpty) continue;

      if (line.startsWith(' ') || line.startsWith('\t')) {
        issues.add(
          KeyIssue(
            code: KeyIssueCode.nonBase64,
            severity: KeyIssueSeverity.warning,
            line: i + 1,
            message: '第 ${i + 1} 行以空白字符开头，严格解析器会拒绝。可点「清理」自动修掉。',
            fixable: true,
          ),
        );
      }

      final String trimmed = line.trim();
      if (!_base64Re.hasMatch(trimmed)) {
        final String bad = trimmed.runes.map(String.fromCharCode).firstWhere(
              (String c) => !RegExp(r'[A-Za-z0-9+/=]').hasMatch(c),
              orElse: () => '?',
            );
        issues.add(
          KeyIssue(
            code: KeyIssueCode.nonBase64,
            severity: KeyIssueSeverity.blocker,
            line: i + 1,
            message: '第 ${i + 1} 行含非 base64 字符「$bad」。'
                '私钥正文只能是 A–Z a–z 0–9 + / =，可能混入了说明文字或缩进。',
          ),
        );
      }
      body.add(trimmed);
    }

    if (body.isEmpty) {
      return KeyCheckResult(
        issues: const <KeyIssue>[
          KeyIssue(
            code: KeyIssueCode.truncated,
            severity: KeyIssueSeverity.blocker,
            message: '私钥正文为空，BEGIN 与 END 之间没有任何内容。',
          ),
        ],
        normalized: normalized,
      );
    }

    final String joined = body.join();
    if (joined.length < 200) {
      issues.add(
        const KeyIssue(
          code: KeyIssueCode.truncated,
          severity: KeyIssueSeverity.blocker,
          message: '私钥正文过短，不像一把完整的私钥（可能复制时漏了大半）。',
        ),
      );
    } else if (joined.length % 4 != 0) {
      issues.add(
        KeyIssue(
          code: KeyIssueCode.truncated,
          severity: KeyIssueSeverity.warning,
          message: 'base64 长度是 ${joined.length}，不是 4 的倍数，末行可能被截断。',
        ),
      );
    }

    if (!issues.any((KeyIssue i) => i.code == KeyIssueCode.truncated)) {
      try {
        base64.decode(joined);
      } on FormatException {
        issues.add(
          const KeyIssue(
            code: KeyIssueCode.nonBase64,
            severity: KeyIssueSeverity.blocker,
            message: 'base64 解码失败，内容可能被编辑器重排过换行。'
                '请用 cat id_ed25519 重新复制。',
          ),
        );
      }
    }

    return KeyCheckResult(issues: issues, normalized: normalized);
  }

  /// 一键清理：去掉不可见字符与每行首尾空白，统一行尾。
  ///
  /// 只在用户主动点「清理」时调用 —— 静默清理会掩盖「哪里出了问题」，
  /// 用户下次还会粘错同样的东西。
  static String repair(String raw) {
    final String text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = text.split('\n');
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < lines.length; i++) {
      String line = lines[i];
      for (final int rune in _invisibleNames.keys) {
        line = line.replaceAll(String.fromCharCode(rune), '');
      }
      buffer.write(line.trim());
      if (i != lines.length - 1) buffer.write('\n');
    }
    return buffer.toString().trim();
  }
}
