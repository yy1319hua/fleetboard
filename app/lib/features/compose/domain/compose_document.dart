/// Compose YAML 的「就地改写」领域逻辑。
///
/// 为什么不能 `YamlMap → jsonEncode → 重新序列化`：
///  - 注释全丢（用户写的 `# 这个端口对外暴露，勿改` 是运维知识，丢了就找不回来）；
///  - 锚点/别名（`x-common: &common` + `<<: *common`）会被展开，文件体积翻倍且
///    失去「一处改处处生效」的结构；
///  - 引号风格与键顺序被打乱（`"80:80"` 变 `80:80`、`ports` 跑到 `image` 前面），
///    用户下次在 Web 端或命令行看同一个文件会以为被谁改过。
///
/// 所以唯一正确的做法是 `package:yaml_edit` 的 `YamlEditor.update(path, value)`：
/// 它在**原文的字节区间**上做外科手术，只替换目标节点的 span，其余字符一个不动。
///
/// 另一个真坑：path 必须是 `List<Object>`（逐段一个元素）。如果图省事拼成
/// `['services', 'web.api', 'image']`，`web.api` 会被当成**两级**键去插入
/// （`services: {web: {api: ...}}`），既不报错也不改到目标——服务名里带 `.`
/// （`db.main`、`nginx.1`）在 compose 里完全合法，这种错误会静默写坏文件。
/// 本文件所有 path 都由 `_path(...)` 逐段构造，禁止字符串拼接。
library;

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// 表单可编辑的字段。顺序即页面展示顺序，与 compose 官方文档的常用度一致。
enum ComposeFieldKey { image, ports, environment, volumes, restart, command }

extension ComposeFieldMeta on ComposeFieldKey {
  String get label => switch (this) {
        ComposeFieldKey.image => '镜像',
        ComposeFieldKey.ports => '端口映射',
        ComposeFieldKey.environment => '环境变量',
        ComposeFieldKey.volumes => '挂载',
        ComposeFieldKey.restart => '重启策略',
        ComposeFieldKey.command => '启动命令',
      };

  String get hint => switch (this) {
        ComposeFieldKey.image => 'nginx:1.27-alpine',
        ComposeFieldKey.ports => '每行一条，如 8080:80',
        ComposeFieldKey.environment => '每行一条，如 TZ=Asia/Shanghai',
        ComposeFieldKey.volumes => '每行一条，如 ./data:/data',
        ComposeFieldKey.restart => 'no / always / unless-stopped / on-failure',
        ComposeFieldKey.command => '留空用镜像默认 CMD；原文是列表时每行一个参数',
      };

  /// 多行字段：列表/映射型，一行一条。
  bool get isMultiLine => switch (this) {
        ComposeFieldKey.ports ||
        ComposeFieldKey.environment ||
        ComposeFieldKey.volumes ||
        ComposeFieldKey.command =>
          true,
        ComposeFieldKey.image || ComposeFieldKey.restart => false,
      };
}

/// 一个字段在表单里的呈现。
class ComposeField {
  const ComposeField({
    required this.text,
    this.existed = false,
    this.blockedReason,
    this.shapeNote,
  });

  /// 文本形态：多行字段用 `\n` 分隔。
  final String text;

  /// 原文里是否已有该键。决定「清空输入」是 `remove` 还是「什么都不做」。
  final bool existed;

  /// 非空表示**不能**按表单改写，页面要显示原因并引导到原文编辑，
  /// 而不是给出一个会把文件写坏的输入框。
  final String? blockedReason;

  /// 结构提示（如「原文是列表写法」），不影响可编辑性。
  final String? shapeNote;

  bool get editable => blockedReason == null;

  static const ComposeField empty = ComposeField(text: '');
}

/// 一个 compose 服务（`services.<name>`）。
class ComposeService {
  const ComposeService({required this.name, required this.fields});

  final String name;
  final Map<ComposeFieldKey, ComposeField> fields;

  ComposeField operator [](ComposeFieldKey key) =>
      fields[key] ?? ComposeField.empty;

  bool get fullyBlocked =>
      ComposeFieldKey.values.every((k) => !this[k].editable);
}

/// 解析结果：成功时 [services] 非空，失败时 [error] 是给用户看的简体中文原因。
class ComposeParseResult {
  const ComposeParseResult(this.services, [this.error]);

  final List<ComposeService> services;
  final String? error;

  bool get ok => error == null;
}

/// 解析 compose 文本，抽出每个服务里可由表单安全编辑的字段。
///
/// 只做「读」：任何结构复杂到无法安全回写的字段（长语法 ports、锚点引用、
/// 非标量值）都会被标记 `blockedReason`，由 UI 引导用户切到原文编辑。
ComposeParseResult parseComposeServices(String source) {
  if (source.trim().isEmpty) {
    return const ComposeParseResult(<ComposeService>[], '文件内容为空');
  }

  final YamlNode root;
  try {
    root = loadYamlNode(source);
  } on YamlException catch (e) {
    final line = (e.span?.start.line ?? 0) + 1;
    return ComposeParseResult(<ComposeService>[], 'YAML 语法错误（第 $line 行）：${e.message}');
  }

  if (root is! YamlMap) {
    return const ComposeParseResult(
      <ComposeService>[],
      '顶层不是映射：compose 文件应以 services: 开头',
    );
  }

  // 注意：YamlMap 的 operator [] 返回**未包装**的值（String/int/List...），
  // 要拿 YamlNode 必须走 `.nodes`。用 [] 去判断 `is YamlMap` 会永远为 false。
  final services = root.nodes['services'];
  if (services is! YamlMap) {
    return const ComposeParseResult(
      <ComposeService>[],
      '没有找到 services: 段，无法按服务列出字段',
    );
  }

  final out = <ComposeService>[];
  for (final entry in services.nodes.entries) {
    // services.nodes 的键是**未包装**的 YAML 值；toString 只是兜底（服务名总是字符串）。
    final name = entry.key.toString();
    final node = entry.value;
    if (node is! YamlMap) {
      out.add(ComposeService(
        name: name,
        fields: {
          for (final key in ComposeFieldKey.values)
            key: const ComposeField(
              text: '',
              blockedReason: '该服务的定义不是映射（可能是锚点引用 *xxx），请用「原文」编辑',
            ),
        },
      ));
      continue;
    }
    // YAML 合并键 `<<: *common`：yaml_edit 在含别名的映射上会直接抛 AliasException
    // （它无法确定你只想改这一处、还是想改所有引用方）。这是真实世界 compose 文件
    // 里极常见的写法，所以必须在**解析阶段**就判定为不可表单编辑，
    // 而不是让用户改半天字段、每次都被弹一句「改不了」。
    if (node.containsKey('<<')) {
      out.add(ComposeService(
        name: name,
        fields: {
          for (final key in ComposeFieldKey.values)
            key: const ComposeField(
              text: '',
              blockedReason:
                  '该服务用了 YAML 合并键（<<: *xxx），就地改写会波及所有引用同一个锚点的服务，'
                  '已按规则禁止；请用「原文」编辑',
            ),
        },
      ));
      continue;
    }
    out.add(ComposeService(name: name, fields: _fieldsOf(node)));
  }

  // services 为空映射时不算失败，但要给出解释，否则表单是空白一片。
  return ComposeParseResult(out);
}

Map<ComposeFieldKey, ComposeField> _fieldsOf(YamlMap service) {
  return <ComposeFieldKey, ComposeField>{
    ComposeFieldKey.image: _scalarField(service, 'image'),
    ComposeFieldKey.ports: _listField(
      service,
      'ports',
      blockedReason: 'ports 里有长语法（对象）写法，按字段改会丢掉 target/published 等键',
    ),
    ComposeFieldKey.environment: _environmentField(service),
    ComposeFieldKey.volumes: _listField(
      service,
      'volumes',
      blockedReason: 'volumes 里有长语法（对象）写法，按字段改会丢掉 type/read_only 等键',
    ),
    ComposeFieldKey.restart: _scalarField(service, 'restart'),
    ComposeFieldKey.command: _scalarField(
      service,
      'command',
      allowList: true,
      blockedReason: 'command 既不是标量也不是字符串列表',
    ),
  };
}

ComposeField _scalarField(
  YamlMap service,
  String key, {
  bool allowList = false,
  String blockedReason = '值不是单行标量',
}) {
  final node = service.nodes[key];
  final existed = service.containsKey(key);
  if (node == null) return ComposeField(text: '', existed: existed);

  if (allowList && node is YamlList) {
    final lines = _scalarLines(node);
    if (lines == null) {
      return ComposeField(text: '', existed: existed, blockedReason: blockedReason);
    }
    return ComposeField(
      text: lines.join('\n'),
      existed: existed,
      shapeNote: '原文是列表写法，每行会被写成一个参数',
    );
  }

  final text = _scalarText(node);
  if (text == null) {
    return ComposeField(text: '', existed: existed, blockedReason: blockedReason);
  }
  return ComposeField(text: text, existed: existed);
}

ComposeField _listField(
  YamlMap service,
  String key, {
  required String blockedReason,
}) {
  final node = service.nodes[key];
  final existed = service.containsKey(key);
  if (node == null) return ComposeField(text: '', existed: existed);
  if (node is! YamlList) {
    return ComposeField(
      text: '',
      existed: existed,
      blockedReason: '$key 不是列表写法，请用「原文」编辑',
    );
  }
  final lines = _scalarLines(node);
  if (lines == null) {
    return ComposeField(text: '', existed: existed, blockedReason: blockedReason);
  }
  return ComposeField(text: lines.join('\n'), existed: existed);
}

ComposeField _environmentField(YamlMap service) {
  final node = service.nodes['environment'];
  final existed = service.containsKey('environment');
  if (node == null) return ComposeField(text: '', existed: existed);

  if (node is YamlMap) {
    final lines = <String>[];
    for (final entry in node.nodes.entries) {
      final value = entry.value;
      final text = value is YamlScalar ? (value.value?.toString() ?? '') : null;
      if (text == null) {
        return ComposeField(
          text: '',
          existed: existed,
          blockedReason: 'environment 里有非标量值，请用「原文」编辑',
        );
      }
      lines.add('${entry.key}=$text');
    }
    return ComposeField(
      text: lines.join('\n'),
      existed: existed,
      shapeNote: '原文是映射写法，改动会逐键打进原文，其余键与注释保持原样',
    );
  }

  if (node is YamlList) {
    final lines = _scalarLines(node);
    if (lines == null) {
      return ComposeField(
        text: '',
        existed: existed,
        blockedReason: 'environment 里有非标量条目，请用「原文」编辑',
      );
    }
    return ComposeField(text: lines.join('\n'), existed: existed);
  }

  return ComposeField(
    text: '',
    existed: existed,
    blockedReason: 'environment 既不是映射也不是列表，请用「原文」编辑',
  );
}

/// 列表节点 → 每行的字符串；含非标量条目时返回 null（不能安全回写）。
List<String>? _scalarLines(YamlList list) {
  final out = <String>[];
  for (final node in list.nodes) {
    final text = _scalarText(node);
    if (text == null) return null;
    out.add(text);
  }
  return out;
}

/// 标量节点 → 文本；非标量返回 null。
String? _scalarText(YamlNode node) {
  if (node is YamlScalar) {
    final value = node.value;
    return value == null ? '' : value.toString();
  }
  return null;
}

// ---------------------------------------------------------------------------
// 写：把表单改动打进原文
// ---------------------------------------------------------------------------

/// 表单里「某个服务的若干字段」的新值。
///
/// `null` = 该字段没动（保持原文，包括原文里的注释与顺序）；
/// 空字符串 / 空列表 = 用户清空了，语义是**删掉这个键**让 compose 回落默认值。
class ServiceEdit {
  const ServiceEdit({
    required this.serviceName,
    this.image,
    this.ports,
    this.environment,
    this.volumes,
    this.restart,
    this.command,
  });

  final String serviceName;
  final String? image;
  final List<String>? ports;
  final List<String>? environment;
  final List<String>? volumes;
  final String? restart;
  final String? command;

  bool get isEmpty =>
      image == null &&
      ports == null &&
      environment == null &&
      volumes == null &&
      restart == null &&
      command == null;
}

/// 就地改写失败（锚点、路径不存在、yaml_edit 自检不通过等）。
///
/// 单独一个类型是为了让 UI 能区分「用户输入非法」与「这段 YAML 结构不支持
/// 表单改写」——后者必须引导到原文编辑，而不是让用户反复重试同一个字段。
class ComposeEditException implements Exception {
  const ComposeEditException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 把 [edits] 就地打进 [source]，返回新全文；原文其余字节保持不变。
///
/// 关键实现点（也是「不破坏原文」的全部保证）：
///  1. `YamlEditor(source)` 只持有原文与 AST，不会重新序列化整棵树；
///  2. 每处改动都走 `update`/`remove`，只替换目标 span；
///  3. 值没变化的字段**跳过**，避免「打开表单看一眼就弄脏文件」；
///  4. 清空输入 = 删键（compose 回落默认值），而不是写入空字符串。
String applyComposeEdits(String source, List<ServiceEdit> edits) {
  final YamlNode doc;
  try {
    doc = loadYamlNode(source);
  } on YamlException catch (e) {
    throw ComposeEditException('当前文本不是合法 YAML（第 ${(e.span?.start.line ?? 0) + 1} 行）：${e.message}');
  }

  final editor = YamlEditor(source);
  try {
    for (final edit in edits) {
      if (edit.isEmpty) continue;
      // 逐段构造 path：服务名整体作为**一段**，含 `.` 也不会被拆开。
      final servicePath = _append(<Object>['services'], edit.serviceName);

      if (edit.image != null) {
        _writeScalar(editor, doc, _join(servicePath, 'image'), edit.image!);
      }
      if (edit.restart != null) {
        _writeScalar(editor, doc, _join(servicePath, 'restart'), edit.restart!);
      }
      if (edit.command != null) {
        _writeCommand(editor, doc, _join(servicePath, 'command'), edit.command!);
      }
      if (edit.ports != null) {
        _writeStringList(editor, doc, _join(servicePath, 'ports'), edit.ports!);
      }
      if (edit.volumes != null) {
        _writeStringList(
            editor, doc, _join(servicePath, 'volumes'), edit.volumes!);
      }
      if (edit.environment != null) {
        _writeEnvironment(
            editor, doc, _join(servicePath, 'environment'), edit.environment!);
      }
    }
  } on AliasException catch (e) {
    throw ComposeEditException(
      '这段 YAML 用到了锚点/别名（& / *），就地改写可能波及别的服务，'
      '已拒绝写入。请用「原文」编辑：${e.message.split('\n').first}',
    );
  } on ArgumentError catch (e) {
    // yaml_edit 的 PathError 未导出，但它是 ArgumentError 的子类（路径走不通时抛）。
    throw ComposeEditException('字段路径无法定位：${e.message}');
  } on AssertionError catch (e) {
    // yaml_edit 每次改动后会做一次深度相等自检；不通过说明这种结构它表示不了。
    throw ComposeEditException(
      '这种写法 yaml_edit 无法原地表示（会改变语义），请用「原文」编辑。'
      '${e.message ?? ''}',
    );
  }

  return editor.toString();
}

/// 在既有 path 后追加**一段**（不是拼接字符串）。
List<Object> _append(List<Object> base, Object segment) =>
    <Object>[...base, segment];

/// 简写：`_join(servicePath, 'image')`。
List<Object> _join(List<Object> base, Object segment) => _append(base, segment);

/// 取原文里的节点（用于判断键是否存在、以及原值是哪种结构）。缺失返回 null。
YamlNode? _nodeAt(YamlNode doc, List<Object> path) {
  YamlNode current = doc;
  for (final segment in path) {
    if (current is YamlMap) {
      if (!current.containsKey(segment)) return null;
      final next = current.nodes[segment];
      if (next is! YamlNode) return null;
      current = next;
    } else if (current is YamlList) {
      if (segment is! int) return null;
      if (segment < 0 || segment >= current.nodes.length) return null;
      current = current.nodes[segment];
    } else {
      return null;
    }
  }
  return current;
}

void _writeScalar(
  YamlEditor editor,
  YamlNode doc,
  List<Object> path,
  String value,
) {
  final existed = _nodeAt(doc, path) != null;
  final text = value.trim();
  if (text.isEmpty) {
    // 清空 = 删键，让 compose 用镜像默认值；写空串会变成 image: "" 直接起不来。
    if (existed) editor.remove(path);
    return;
  }
  if (text.contains('\n')) {
    throw const ComposeEditException('该字段只能是一行，请去掉换行');
  }
  final old = _nodeAt(doc, path);
  if (old is YamlScalar && old.value?.toString() == text) return;
  editor.update(path, text);
}

void _writeCommand(
  YamlEditor editor,
  YamlNode doc,
  List<Object> path,
  String value,
) {
  final node = _nodeAt(doc, path);
  final text = value.trim();
  if (text.isEmpty) {
    if (node != null) editor.remove(path);
    return;
  }
  if (node is YamlList) {
    // 原文是列表（每行一个参数）：保持列表形状，否则会把 `sh -c "..."` 变成单个 arg。
    final args = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (args.isEmpty) {
      editor.remove(path);
      return;
    }
    if (_sameStrings(node, args)) return;
    editor.update(path, args);
    return;
  }
  if (node is YamlScalar && node.value?.toString() == text) return;
  editor.update(path, text);
}

void _writeStringList(
  YamlEditor editor,
  YamlNode doc,
  List<Object> path,
  List<String> values,
) {
  final node = _nodeAt(doc, path);
  // 注意：端口里的 `8080:80` 必须保留成字符串，yaml_edit 会自行决定加不加引号。
  final items = values
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (items.isEmpty) {
    if (node != null) editor.remove(path);
    return;
  }
  if (node is YamlList && _sameStrings(node, items)) return;
  editor.update(path, items);
}

/// environment 两种合法写法都要照顾：
///  - 映射写法（`KEY: value`）：**逐键**改，只动真正变化的键，注释/顺序原样保留；
///  - 列表写法（`- KEY=value`）：整段替换（列表里没有可保留的注释）。
void _writeEnvironment(
  YamlEditor editor,
  YamlNode doc,
  List<Object> path,
  List<String> lines,
) {
  final node = _nodeAt(doc, path);

  final pairs = <String, String>{};
  final inherited = <String>{};
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) {
      // 只写键名 = 从宿主机继承同名变量，是合法写法，不能当成语法错误丢掉。
      inherited.add(line);
      continue;
    }
    pairs[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }

  if (node is YamlMap) {
    // 用户把环境变量全删了：直接删掉整个 environment 键，而不是逐个删键
    // （逐个删会留下 `environment: {}` 这种"看起来还在"的空壳）。
    if (pairs.isEmpty && inherited.isEmpty) {
      editor.remove(path);
      return;
    }
    for (final key in node.nodes.keys.toList()) {
      final keyText = key.toString();
      if (pairs.containsKey(keyText) || inherited.contains(keyText)) continue;
      // 传原始键对象，而不是 toString 的结果：数字键（`8080`）也能正确命中。
      editor.remove(_join(path, key));
    }
    pairs.forEach((key, value) {
      final old = node.nodes[key];
      final oldText = old is YamlScalar ? (old.value?.toString() ?? '') : null;
      if (oldText == value) return;
      editor.update(_join(path, key), value);
    });
    return;
  }

  final items = <String>[
    for (final entry in pairs.entries) '${entry.key}=${entry.value}',
    ...inherited,
  ];
  if (node is YamlList && _sameStrings(node, items)) return;
  if (items.isEmpty) {
    if (node != null) editor.remove(path);
    return;
  }
  editor.update(path, items);
}

bool _sameStrings(YamlList node, List<String> values) {
  if (node.nodes.length != values.length) return false;
  for (var i = 0; i < values.length; i++) {
    final text = _scalarText(node.nodes[i]);
    if (text == null || text.trim() != values[i]) return false;
  }
  return true;
}
