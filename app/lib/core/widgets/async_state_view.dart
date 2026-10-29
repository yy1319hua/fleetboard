import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/api_exception.dart';

/// 四态合一的异步视图（加载 / 错误 / 空 / 有数据）。
///
/// 为什么必须统一：App 里有二十多个数据页，如果每页各写一遍 `when(...)`，
/// 迟早会出现「有数据但空白」「错误只显示一行红字、没有重试按钮」「空列表
/// 什么都不显示」这类半成品。这里把四态收口，并且**强制要求空态文案**
/// （[emptyHint] 是必填参数）——空态说不出「为什么空」的页面，本质上就是没做完。
///
/// 约定：错误态一定给可执行动作（[onRetry] 或 [errorAction]），
/// 只显示错误文案而不给下一步的，用户除了杀进程没有别的选择。
class AsyncStateView<T> extends StatelessWidget {
  const AsyncStateView({
    super.key,
    required this.value,
    required this.emptyHint,
    required this.builder,
    this.onRetry,
    this.isEmpty,
    this.errorAction,
    this.loadingHint,
    this.padding = const EdgeInsets.all(16),
  });

  final AsyncValue<T> value;

  /// 空态文案（必填）。要说清「为什么空」以及「怎么让它不空」。
  final String emptyHint;

  final Widget Function(T data) builder;

  /// 重试回调。为 null 时错误态只展示文案（离线场景需要调用方自行判断是否可重试）。
  final VoidCallback? onRetry;

  /// 自定义空态判定（列表默认按 `isEmpty` 判断，对象型数据由调用方给出）。
  final bool Function(T data)? isEmpty;

  /// 错误态下方的补充动作（例如「去设置里检查服务器地址」）。
  final Widget? errorAction;

  final String? loadingHint;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            if (loadingHint != null) ...[
              const SizedBox(height: 12),
              Text(
                loadingHint!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      error: (error, _) => _ErrorState(
        message: describeApiError(error),
        onRetry: onRetry,
        extraAction: errorAction,
        padding: padding,
      ),
      data: (data) {
        final empty = isEmpty?.call(data) ?? _defaultIsEmpty(data);
        if (empty) {
          return _EmptyState(
            hint: emptyHint,
            onRetry: onRetry,
            padding: padding,
          );
        }
        return builder(data);
      },
    );
  }

  static bool _defaultIsEmpty(Object? data) {
    if (data is Iterable) return data.isEmpty;
    if (data is Map) return data.isEmpty;
    if (data is String) return data.isEmpty;
    return false;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.hint,
    required this.onRetry,
    required this.padding,
  });

  final String hint;
  final VoidCallback? onRetry;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
    required this.extraAction,
    required this.padding,
  });

  final String message;
  final VoidCallback? onRetry;
  final Widget? extraAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (onRetry != null)
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            if (extraAction != null) ...[
              const SizedBox(height: 8),
              extraAction!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 轻量错误条：用于「已有数据、但本次刷新失败」的场景。
///
/// 这种情况下不该整页替换成错误态——用户手里的旧数据仍然有价值，
/// 只需要一条可关闭的提示说明「现在看到的是缓存」。
class InlineErrorBar extends StatelessWidget {
  const InlineErrorBar({
    super.key,
    required this.message,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                child: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }
}
