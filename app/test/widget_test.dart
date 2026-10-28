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
  Future<String?> readUsername() async => null;
}

void main() {
  testWidgets('登录页渲染：三输入 + 登录按钮', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        secureStoreProvider.overrideWithValue(FakeSecureStore()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 三个输入字段（按 label 文案）。
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    // 登录按钮。
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
  });
}
