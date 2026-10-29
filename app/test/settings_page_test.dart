import 'package:app/core/storage/secure_store.dart';
import 'package:app/features/auth/application/auth_notifier.dart';
import 'package:app/features/auth/data/auth_repository.dart';
import 'package:app/features/settings/presentation/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 需求来源：M11.1「不要出半成品」——设置页从只读改为入口分组。
///
/// 这个测试守两件事：
/// ① 五个入口一个都不能少（入口缺失＝功能不可达，属于可见缺陷）；
/// ② 「首版只读」那条占位提示必须已经消失（留着就是自相矛盾的半成品）。
void main() {
  testWidgets('设置根页展示五个入口且不再有只读占位', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          // SecureStore 不实际读写（本页只取内存里的会话快照），
          // 避免 flutter_secure_storage 在测试环境因缺插件而抛错。
          authNotifierProvider.overrideWith(
            (Ref ref) => AuthNotifier(
              secureStore: const SecureStore(),
              authRepository: AuthRepository(),
            ),
          ),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pump();

    for (final label in <String>['通知推送', '采集与保留', '服务器纳管', '账户与安全', '关于']) {
      expect(find.text(label), findsOneWidget, reason: '缺少入口：$label');
    }
    expect(find.textContaining('首版只读'), findsNothing);

    // 未登录时也要能渲染（显示占位用户名），不能白屏或抛异常。
    expect(tester.takeException(), isNull);
    expect(find.text('-'), findsOneWidget);
  });
}
