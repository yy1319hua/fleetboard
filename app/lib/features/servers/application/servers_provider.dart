import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../overview/domain/bootstrap.dart';
import '../data/servers_repository.dart';

/// 纳管服务器列表。
///
/// 用 `autoDispose`：离开页面即释放。纳管页不是常驻页，若常驻会在每次
/// 回到列表时保留一份可能已过期的数据，反而需要在更多地方 invalidate。
final serversProvider = FutureProvider.autoDispose<List<Server>>((ref) {
  return ref.watch(serversRepositoryProvider).list();
});
