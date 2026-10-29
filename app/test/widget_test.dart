import 'package:app/core/storage/secure_store.dart';
import 'package:app/features/auth/presentation/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 auth_notifier_test 中同形的安全存储假体（独立 library，类名隔离）。
class FakeSecureStore extends SecureStore {
  @override
  Future<String?> readBaseUrl() async => null;
  @override
  Future<void> writeBaseUrl(String baseUrl) async {}
  @override
  Future<String?> readUsername() async => null;
}

Widget _wrap(Widget child) {
  return UncontrolledProviderScope(
    container: ProviderContainer(
      overrides: [
        secureStoreProvider.overrideWithValue(FakeSecureStore()),
      ],
    ),
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('登录页渲染：两输入 + 登录按钮（M10.2 起无服务器地址输入）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const LoginPage()));
    await tester.pumpAndSettle();

    // 只保留用户名 + 密码两个输入字段。
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    // 地址不再由用户手填：输入框 label 与旧校验文案都不应出现。
    expect(find.text('服务器地址'), findsNothing);
    expect(find.text('请输入服务器地址'), findsNothing);
    // 底部只读展示当前连接目标（未注入默认地址时提示未配置）。
    expect(find.textContaining('服务器'), findsOneWidget);
  });

  testWidgets('隐藏入口：连点标题 7 次弹出服务器地址对话框',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const LoginPage()));
    await tester.pumpAndSettle();

    final title = find.text('随身扳手 · 应急运维');
    expect(title, findsOneWidget);

    // 连点 6 次不应触发。
    for (var i = 0; i < 6; i++) {
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    expect(find.text('保存'), findsNothing);

    // 第 7 次触发改址对话框。
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.text('服务器地址'), findsWidgets);
    expect(find.widgetWithText(FilledButton, '保存'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
  });
}
