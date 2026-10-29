import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/code_editor.dart';
import '../../../core/widgets/hold_to_confirm.dart';
import '../application/compose_file_notifier.dart';
import '../domain/compose_document.dart';
import '../domain/compose_models.dart';
import 'compose_form_view.dart';
import 'diff_confirm_sheet.dart';

enum _Mode { read, form, source }

/// 单个 compose 文件的编排页：只读全文 / 表单编辑 / 原文编辑 / 动作执行。
///
/// 三条硬规则（都是为了让"改配置"这件事不产生静默损坏）：
///  1. 任何写回（表单改动、原文改动、剪贴板整份替换）都先在内存里生成新全文，
///     用 [DiffView] 让用户看一眼再 PUT —— 写错的 compose 会让服务起不来，
///     而用户手上通常没有备份。
///  2. 表单改动只走 `YamlEditor.update/remove` 打在原文上，绝不做 Map ↔ YAML
///     整体序列化（会丢注释、锚点、引号风格、键顺序）。
///  3. `down` 用 [HoldToConfirm]（1.5s 持续按压）：它会停掉整组容器，误触代价高，
///     而二次确认弹窗对误触几乎没有拦截力（用户会条件反射点"确定"）。
///
/// 关于「服务状态」：后端 compose 接口不返回容器状态（`compose.FileItem` 只有
/// name/path/size/mod_time），所以这里不显示运行状态，也不去和 `docker ps` 的
/// 容器名做模糊匹配 —— 用 project 前缀猜状态在运维场景里是危险的（会把 A 服务的
/// 状态显示成 B 的）。真实状态在「容器」Tab 里看，页面里给了一句指引。
class ComposeFilePage extends ConsumerStatefulWidget {
  const ComposeFilePage({
    super.key,
    required this.serverId,
    required this.path,
    this.name,
  });

  final int serverId;

  /// 绝对路径（服务端要求白名单内路径，客户端不做前缀校验以免与设置不同步）。
  final String path;

  final String? name;

  @override
  ConsumerState<ComposeFilePage> createState() => _ComposeFilePageState();
}

class _ComposeFilePageState extends ConsumerState<ComposeFilePage> {
  _Mode _mode = _Mode.read;

  /// 切换模式时 +1：编辑器按 key 重建，从而丢弃上一个模式的输入状态。
  int _modeEpoch = 0;

  ComposeFileKey get _key =>
      (serverId: widget.serverId, path: widget.path);

  ComposeFileNotifier get _notifier =>
      ref.read(composeFileProvider(_key).notifier);

  String get _fileName =>
      widget.name ?? widget.path.split('/').last;

  String get _projectDir {
    final index = widget.path.lastIndexOf('/');
    return index <= 0 ? '/' : widget.path.substring(0, index);
  }

  void _switchMode(_Mode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _modeEpoch++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(composeFileProvider(_key));

    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'import':
                  _importFromClipboard(state);
                case 'reload':
                  _reload(state);
                case 'copy':
                  _copyPath();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'import',
                child: Text('从剪贴板粘贴整份'),
              ),
              PopupMenuItem<String>(
                value: 'reload',
                child: Text('重新加载（丢弃改动）'),
              ),
              PopupMenuItem<String>(
                value: 'copy',
                child: Text('复制文件路径'),
              ),
            ],
          ),
        ],
      ),
      body: state.loading
          ? const _LoadingBody()
          : state.loadError != null
              ? _LoadErrorBody(
                  message: state.loadError!,
                  path: widget.path,
                  onRetry: () => ref.invalidate(composeFileProvider(_key)),
                )
              : _buildLoaded(state),
      bottomNavigationBar: _buildSaveBar(state),
    );
  }

  Widget _buildLoaded(ComposeFileState state) {
    return Column(
      children: [
        _PathBar(
          path: widget.path,
          projectDir: _projectDir,
          dirty: state.dirty,
          // 用 UTF-8 字节数而不是 String.length：中文注释一个字 3 字节，
          // 显示字符数会让"文件多大"这个判断失真（后端报的也是字节）。
          sizeText: formatComposeSize(utf8.encode(state.draft).length),
        ),
        _ModeBar(
          mode: _mode,
          onChanged: _switchMode,
          // 只读态给一个显式的「编辑」入口：用户读代码时第一反应是找编辑按钮，
          // 而不是回头发现上面还有个分段控件。
          onEdit: _mode == _Mode.read ? () => _switchMode(_Mode.form) : null,
        ),
        _ActionBar(
          busyAction: state.busyAction,
          saving: state.saving,
          onRun: _runAction,
          // down 的确认由长按本身完成（1.5s 持续按压），再弹一次确认框就是双确认。
          onDown: () => _runAction('down', preConfirmed: true),
        ),
        const Divider(height: 1),
        Expanded(child: _buildContent(state)),
      ],
    );
  }

  Widget _buildContent(ComposeFileState state) {
    final parsed = state.parsed;

    switch (_mode) {
      case _Mode.read:
        return _CodeView(
          key: ValueKey<String>('read-$_modeEpoch-${state.revision}'),
          text: state.draft,
          readOnly: true,
        );
      case _Mode.source:
        return _CodeView(
          key: ValueKey<String>('source-$_modeEpoch-${state.revision}'),
          text: state.draft,
          readOnly: false,
          onChanged: _notifier.editSource,
        );
      case _Mode.form:
        return ComposeFormView(
          key: ValueKey<String>('form-$_modeEpoch-${state.revision}'),
          services: parsed.services,
          revision: state.revision,
          parseError: parsed.error,
          onRequestSourceEdit: () => _switchMode(_Mode.source),
          onEdit: (edit) => _notifier.applyEdit(edit),
        );
    }
  }

  Widget? _buildSaveBar(ComposeFileState state) {
    if (!state.dirty && !state.saving) return null;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                state.saving ? '正在写回…' : '有未保存改动',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: state.saving ? null : () => _confirmDiscard(state),
              child: const Text('放弃改动'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: state.saving ? null : () => _save(state),
              icon: state.saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.visibility_outlined, size: 18),
              label: const Text('预览并保存'),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 写回
  // -------------------------------------------------------------------------

  Future<void> _save(ComposeFileState state) async {
    if (!state.dirty) return;
    final parsed = state.parsed;

    final confirmed = await showDiffConfirm(
      context,
      title: '写回 $_fileName',
      subtitle: widget.path,
      before: state.original,
      after: state.draft,
      confirmLabel: '确认写回',
      warning: parsed.ok
          ? null
          : '当前文本不是合法 YAML：${parsed.error}。写回后 docker compose 会拒绝执行。',
    );
    if (!confirmed) return;

    try {
      final size = await _notifier.save();
      if (!mounted) return;
      _toast('已写回服务器（$size 字节）');
    } on Object catch (e) {
      if (!mounted) return;
      _toast('保存失败：${describeApiError(e)}');
    }
  }

  Future<void> _confirmDiscard(ComposeFileState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃未保存的改动？'),
        content: const Text('编辑区会回到服务器上的当前内容，这次修改不会写回。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('放弃改动'),
          ),
        ],
      ),
    );
    if (ok == true) _notifier.discard();
  }

  // -------------------------------------------------------------------------
  // 剪贴板整份导入
  // -------------------------------------------------------------------------

  Future<void> _importFromClipboard(ComposeFileState state) async {
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } on Object {
      if (mounted) _toast('读取剪贴板失败，请确认 App 有剪贴板权限');
      return;
    }
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (mounted) _toast('剪贴板里没有文本内容');
      return;
    }
    if (text == state.draft) {
      if (mounted) _toast('剪贴板内容与当前内容完全一致，无需导入');
      return;
    }

    final parsed = parseComposeServices(text);
    if (!mounted) return;
    final confirmed = await showDiffConfirm(
      context,
      title: '用剪贴板内容整份替换',
      subtitle: '只替换编辑区，不会立刻写回服务器；下一步还要点「预览并保存」。',
      before: state.draft,
      after: text,
      confirmLabel: '替换编辑区',
      warning: parsed.ok
          ? (parsed.services.isEmpty
              ? '这段内容里没有解析出任何服务（services: 为空或缺失）。'
              : null)
          : '这段内容不是合法 YAML：${parsed.error}。写回后 docker compose 会拒绝执行。',
    );
    if (!confirmed) return;

    _notifier.replaceAll(text);
    _switchMode(_Mode.source);
    if (mounted) _toast('已替换为剪贴板内容，确认无误后点「预览并保存」写回');
  }

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  Future<void> _reload(ComposeFileState state) async {
    if (state.dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('重新加载？'),
          content: const Text('未保存的改动会丢失，编辑区将回到服务器上的当前内容。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    ref.invalidate(composeFileProvider(_key));
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.path));
    if (mounted) _toast('已复制路径');
  }

  Future<void> _runAction(String action, {bool preConfirmed = false}) async {
    // up / restart / ps 都是单击 → 确认弹层 → 执行（down 由长按自身完成确认）。
    // 弹层里同时显示**将被执行的完整命令**：用户能核对路径与参数，
    // 这份信息在后端只回传"成功/退出码"时尤其重要。
    if (!preConfirmed) {
      final confirmed = await _confirmRun(action);
      if (confirmed != true) return;
    }
    try {
      final result = await _notifier.runAction(action);
      if (!mounted) return;
      await _showOutput(
        action: result.action,
        output: result.output,
        error: null,
      );
    } on Object catch (e) {
      if (!mounted) return;
      // 后端失败时只回传 msg（含退出码），命令输出没有随失败响应下传，
      // 所以这里必须给出「去哪看完整输出」，否则用户只知道失败。
      await _showOutput(
        action: action,
        output: '',
        error: describeApiError(e),
      );
    }
  }

  Future<bool?> _confirmRun(String action) {
    final args = switch (action) {
      'up' => 'up -d',
      'down' => 'down',
      'restart' => 'restart',
      _ => action,
    };
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(action == 'ps'
            ? '查看 compose 容器状态？'
            : '执行 compose ${action.toUpperCase()}？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('将在被管机上执行：'),
            const SizedBox(height: 8),
            SelectableText(
              "docker compose -f '${widget.path}' "
              "--project-directory '$_projectDir' $args",
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('执行'),
          ),
        ],
      ),
    );
  }

  Future<void> _showOutput({
    required String action,
    required String output,
    required String? error,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(error == null ? 'compose $action 输出' : 'compose $action 失败'),
        content: SizedBox(
          width: double.maxFinite,
          // 跟随屏幕高度而不是写死 320：小屏（<600dp）上写死高度会把
          // AlertDialog 撑出可视区域，输出反而看不全。
          height: MediaQuery.sizeOf(dialogContext).height * 0.35,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (error != null) ...[
                Text(
                  error,
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '后端失败时只回传退出码，完整输出请在机器上执行 '
                  'docker compose -f ${widget.path} $action 查看。',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(dialogContext)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      output.isEmpty ? '（没有输出）' : output,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (output.isNotEmpty)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: output));
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('复制输出'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// 局部组件
// ---------------------------------------------------------------------------

/// 路径条：把「哪一个文件、在哪个项目目录、有没有未保存改动」放在一屏内可见。
class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.projectDir,
    required this.dirty,
    required this.sizeText,
  });

  final String path;
  final String projectDir;
  final bool dirty;
  final String sizeText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (dirty)
                Row(
                  children: [
                    Icon(Icons.circle,
                        size: 8, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 4),
                    Text('有未保存改动', style: theme.textTheme.bodySmall),
                    const SizedBox(width: 12),
                  ],
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text('与服务器一致', style: theme.textTheme.bodySmall),
                ),
              Text(
                '$sizeText · 项目目录 $projectDir',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.mode,
    required this.onChanged,
    this.onEdit,
  });

  final _Mode mode;
  final ValueChanged<_Mode> onChanged;

  /// 只读态显示「编辑」按钮；其它态为 null。
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            // 不带图标：360dp 竖屏下三个带图标的 segment 会把文字挤到换行。
            child: SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment<_Mode>(value: _Mode.read, label: Text('全文')),
                ButtonSegment<_Mode>(value: _Mode.form, label: Text('表单')),
                ButtonSegment<_Mode>(value: _Mode.source, label: Text('原文')),
              ],
              selected: {mode},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (value) => onChanged(value.first),
            ),
          ),
          if (onEdit != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('编辑'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 动作条：up / restart / ps 单击执行（up、restart 先确认），down 必须长按 1.5s。
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.busyAction,
    required this.saving,
    required this.onRun,
    required this.onDown,
  });

  final String? busyAction;
  final bool saving;

  /// 需要确认弹层再执行的动作（up / restart / ps）。
  final ValueChanged<String> onRun;

  /// 长按已完成确认，直接执行 down。
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) {
    final busy = busyAction != null || saving;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip(
                  label: '启动 up',
                  icon: Icons.play_arrow_outlined,
                  onPressed: busy ? null : () => onRun('up'),
                ),
                const SizedBox(width: 8),
                _chip(
                  label: '重启',
                  icon: Icons.restart_alt,
                  onPressed: busy ? null : () => onRun('restart'),
                ),
                const SizedBox(width: 8),
                _chip(
                  label: '状态 ps',
                  icon: Icons.view_list_outlined,
                  onPressed: busy ? null : () => onRun('ps'),
                ),
                const SizedBox(width: 8),
                HoldToConfirm(
                  label: '按住停止 down',
                  icon: Icons.stop_circle_outlined,
                  dense: true,
                  enabled: !busy,
                  onConfirmed: onDown,
                ),
              ],
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      saving
                          ? '正在写回文件…'
                          : '正在执行 compose $busyAction…拉镜像或等健康检查时可能要几十秒，请不要退出页面。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );
  }
}

/// 带行号的等宽文本视图。key 由上层控制，key 变即重建（见 [ComposeFilePage]）。
class _CodeView extends StatefulWidget {
  const _CodeView({
    super.key,
    required this.text,
    required this.readOnly,
    this.onChanged,
  });

  final String text;
  final bool readOnly;
  final ValueChanged<String>? onChanged;

  @override
  State<_CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<_CodeView> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: CodeEditor(
        controller: _controller,
        readOnly: widget.readOnly,
        onChanged: widget.onChanged,
        hintText: widget.readOnly ? null : '在这里直接编辑 YAML，保存前会先给你看 diff',
      ),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 12),
          Text('正在读取文件…', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _LoadErrorBody extends StatelessWidget {
  const _LoadErrorBody({
    required this.message,
    required this.path,
    required this.onRetry,
  });

  final String message;
  final String path;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              path,
              textAlign: TextAlign.center,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
            const SizedBox(height: 8),
            Text(
              '读取失败通常是 SSH 连接问题或该路径已不在白名单内；'
              '确认机器可达后重试，也可以回到上一页重新选文件。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
