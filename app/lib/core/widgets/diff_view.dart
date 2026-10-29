import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/material.dart';

/// 单行差异。
enum DiffKind { same, added, removed }

/// 一行 diff 结果（带行内高亮区间，用于「同一行只改了几个字」的场景）。
class DiffLine {
  const DiffLine({
    required this.kind,
    required this.text,
    this.spans = const [],
  });

  final DiffKind kind;
  final String text;

  /// 行内高亮：为 true 的区间是本次真正变化的字符。
  /// 整行新增/删除时为空（整行已经用底色区分，再高亮反而噪）。
  final List<bool> spans;
}

/// 计算两个文本的行级差异（LCS）。
///
/// 为什么自己写 LCS 而不用 `diff_match_patch` 的 `diff_main`：
/// 后者是**字符级**算法，直接喂整篇 YAML 会得到「第 200 个字符变了」这种结果，
/// 落到行上仍然要重新对齐一次。行级 LCS 的规模是行数（几十到几百），代价可忽略，
/// 而结果天然就是 UI 需要的行序列。
///
/// `diff_match_patch` 在这里的具体用途是**行内**高亮（[ _intraSpans ]）：
/// 相邻的一删一增（`- timeout: 5` / `+ timeout: 10`）只有在行内标出变化的字，
/// 用户才能一眼看出改的是数字而不是整行。
List<DiffLine> computeLineDiff(String before, String after) {
  final a = before.isEmpty ? <String>[] : before.replaceAll('\r\n', '\n').split('\n');
  final b = after.isEmpty ? <String>[] : after.replaceAll('\r\n', '\n').split('\n');

  // LCS 动态规划：n*m 最多几百 × 几百，手机端毫秒级。
  final n = a.length;
  final m = b.length;
  final table = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      table[i][j] = a[i] == b[j]
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] >= table[i][j + 1]
              ? table[i + 1][j]
              : table[i][j + 1]);
    }
  }

  final lines = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      lines.add(DiffLine(kind: DiffKind.same, text: a[i]));
      i++;
      j++;
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      lines.add(DiffLine(kind: DiffKind.removed, text: a[i]));
      i++;
    } else {
      lines.add(DiffLine(kind: DiffKind.added, text: b[j]));
      j++;
    }
  }
  while (i < n) {
    lines.add(DiffLine(kind: DiffKind.removed, text: a[i]));
    i++;
  }
  while (j < m) {
    lines.add(DiffLine(kind: DiffKind.added, text: b[j]));
    j++;
  }

  // 相邻的「一段删除 + 一段新增」视为同一处修改，做行内高亮。
  return _annotateIntraLine(lines);
}

List<DiffLine> _annotateIntraLine(List<DiffLine> lines) {
  final out = <DiffLine>[];
  var k = 0;
  while (k < lines.length) {
    if (lines[k].kind == DiffKind.same) {
      out.add(lines[k]);
      k++;
      continue;
    }
    // 收集连续的删除块与新增块。
    final removed = <DiffLine>[];
    while (k < lines.length && lines[k].kind == DiffKind.removed) {
      removed.add(lines[k]);
      k++;
    }
    final added = <DiffLine>[];
    while (k < lines.length && lines[k].kind == DiffKind.added) {
      added.add(lines[k]);
      k++;
    }
    if (removed.isEmpty) {
      // 纯新增：整行标色即可，不做行内高亮。
      out.addAll(added);
      continue;
    }
    if (added.isEmpty) {
      out.addAll(removed);
      continue;
    }
    // 成对行做字符级高亮；行数不等时只有重叠部分配对。
    final pairs = removed.length < added.length ? removed.length : added.length;
    for (var p = 0; p < removed.length; p++) {
      if (p < pairs) {
        final spans = _intraSpans(removed[p].text, added[p].text);
        out.add(DiffLine(
          kind: DiffKind.removed,
          text: removed[p].text,
          spans: spans.$1,
        ));
      } else {
        out.add(removed[p]);
      }
    }
    for (var p = 0; p < added.length; p++) {
      if (p < pairs) {
        final spans = _intraSpans(removed[p].text, added[p].text);
        out.add(DiffLine(
          kind: DiffKind.added,
          text: added[p].text,
          spans: spans.$2,
        ));
      } else {
        out.add(added[p]);
      }
    }
  }
  return out;
}

/// 返回 (旧行高亮, 新行高亮)。长度与各自文本一致。
(List<bool>, List<bool>) _intraSpans(String oldLine, String newLine) {
  final oldSpans = List<bool>.filled(oldLine.length, false);
  final newSpans = List<bool>.filled(newLine.length, false);
  final diffs = DiffMatchPatch().diff(oldLine, newLine);
  var oi = 0;
  var ni = 0;
  for (final d in diffs) {
    final text = d.text;
    switch (d.operation) {
      case DIFF_EQUAL:
        oi += text.length;
        ni += text.length;
      case DIFF_DELETE:
        for (var x = 0; x < text.length && oi + x < oldSpans.length; x++) {
          oldSpans[oi + x] = true;
        }
        oi += text.length;
      case DIFF_INSERT:
        for (var x = 0; x < text.length && ni + x < newSpans.length; x++) {
          newSpans[ni + x] = true;
        }
        ni += text.length;
    }
  }
  return (oldSpans, newSpans);
}

/// 行级 diff 视图。
class DiffView extends StatelessWidget {
  const DiffView({
    super.key,
    required this.before,
    required this.after,
    this.fontSize = 12.5,
  });

  final String before;
  final String after;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = computeLineDiff(before, after);
    final changed = lines.where((l) => l.kind != DiffKind.same).length;

    if (changed == 0) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('内容没有变化', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            '共 ${lines.length} 行，$changed 行有变动',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: lines.length,
            itemBuilder: (context, index) => _DiffLineTile(
              line: lines[index],
              fontSize: fontSize,
            ),
          ),
        ),
      ],
    );
  }
}

class _DiffLineTile extends StatelessWidget {
  const _DiffLineTile({required this.line, required this.fontSize});

  final DiffLine line;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final Color bg;
    final Color fg;
    final String prefix;
    switch (line.kind) {
      case DiffKind.added:
        // 与股票颜色无关：这是 diff 语义（绿=新增），全行业通用。
        bg = isDark ? const Color(0xFF13351F) : const Color(0xFFE6F4EA);
        fg = isDark ? const Color(0xFF7EE2A8) : const Color(0xFF1E6C3A);
        prefix = '+';
      case DiffKind.removed:
        bg = isDark ? const Color(0xFF3B1518) : const Color(0xFFFCE8E6);
        fg = isDark ? const Color(0xFFFF9AA0) : const Color(0xFFA50E0E);
        prefix = '-';
      case DiffKind.same:
        bg = Colors.transparent;
        fg = theme.colorScheme.onSurface;
        prefix = ' ';
    }

    final hasSpans = line.spans.any((e) => e);
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 12,
            child: Text(
              prefix,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: fontSize,
                color: line.kind == DiffKind.same
                    ? theme.colorScheme.outline
                    : fg,
              ),
            ),
          ),
          Expanded(
            child: hasSpans
                ? _spanText(line, fg, fontSize)
                : Text(
                    line.text.isEmpty ? ' ' : line.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: fontSize,
                      color: fg,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 把行内变化区间画成更深的底色（整行已经着色，行内再叠一层）。
  Widget _spanText(DiffLine line, Color fg, double fontSize) {
    final spans = <TextSpan>[];
    final buf = StringBuffer();
    var current = false;
    void flush() {
      if (buf.isEmpty) return;
      spans.add(TextSpan(
        text: buf.toString(),
        style: current
            ? TextStyle(
                // withAlpha 而非 withOpacity/withValues：前者在所有支持的目标
                // Flutter 版本上都未废弃，CI 的 --fatal-infos 不会被弃用告警打红。
                backgroundColor: fg.withAlpha(56),
                fontWeight: FontWeight.w600,
              )
            : null,
      ));
      buf.clear();
    }

    for (var i = 0; i < line.text.length; i++) {
      final flag = i < line.spans.length && line.spans[i];
      if (flag != current) {
        flush();
        current = flag;
      }
      buf.write(line.text[i]);
    }
    flush();
    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: fontSize,
          color: fg,
        ),
        children: spans,
      ),
    );
  }
}
