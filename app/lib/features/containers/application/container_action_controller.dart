import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/containers_repository.dart';
import '../domain/container_action.dart';

/// 单次容器操作的提交状态（提交锁：submitting 时禁重复提交，满足 B6 防重）。
sealed class ActionState {
  const ActionState();
}

class ActionIdle extends ActionState {
  const ActionIdle();
}

class ActionSubmitting extends ActionState {
  const ActionSubmitting();
}

class ActionSuccess extends ActionState {
  const ActionSuccess(this.result);
  final ContainerActionResult result;
}

class ActionFailure extends ActionState {
  const ActionFailure(this.message);
  final String message;
}

class ContainerActionController extends StateNotifier<ActionState> {
  ContainerActionController(this._repo) : super(const ActionIdle());

  final ContainersRepository _repo;

  bool get busy => state is ActionSubmitting;

  /// 提交一次操作；提交中再次调用直接返回 null（提交锁）。
  /// 失败/超时仅置失败态、不自动重试（B6）。
  Future<ContainerActionResult?> submit(
    int serverId,
    String cid,
    ContainerActionType type,
  ) async {
    if (busy) return null;
    state = const ActionSubmitting();
    try {
      final result = await _repo.action(serverId, cid, type);
      state = ActionSuccess(result);
      return result;
    } on Object catch (e) {
      state = ActionFailure('$e');
      return null;
    }
  }

  void reset() => state = const ActionIdle();
}

final containerActionControllerProvider = StateNotifierProvider.autoDispose<
    ContainerActionController, ActionState>(
  (ref) => ContainerActionController(ref.watch(containersRepositoryProvider)),
);
