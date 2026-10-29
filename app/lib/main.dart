import 'dart:async';

import 'package:app/app.dart';
import 'package:app/core/config/app_config.dart';
import 'package:app/core/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> main() async {
  // 确保原生插件（flutter_secure_storage / shared_preferences）在 runApp 前就绪。
  WidgetsFlutterBinding.ensureInitialized();
  // 基址物化不阻塞首帧：runApp 先出画面，安全存储读写放到之后执行
  // （请求侧本就有内置兜底地址，晚一拍写入不影响任何请求）。
  runApp(
    const ProviderScope(
      child: App(),
    ),
  );
  unawaited(_materializeBaseUrl());
}

/// 首启 / 升级后把生效地址物化进 SecureStore（M10.2）。
///
/// 只补不改：已存值原样保留（refresh 续期绑死签发时的域名），仅在无值 / 空值时
/// 写入「dart-define > 内置常量」的默认地址，避免请求侧反复走兜底分支。
Future<void> _materializeBaseUrl() async {
  const store = SecureStore();
  try {
    final stored = await store.readBaseUrl();
    final fallback = AppConfig.normalize(AppConfig.defaultBaseUrl);
    // 未注入默认地址（如本地调试未传 --dart-define）时不写空值，
    // 由登录页显示「未配置服务器地址」。
    if ((stored == null || stored.trim().isEmpty) && fallback.isNotEmpty) {
      await store.writeBaseUrl(fallback);
    }
  } on Object {
    // 安全存储暂不可用（首次装配密钥等）不阻塞启动：请求侧仍有内置兜底地址。
  }
}
