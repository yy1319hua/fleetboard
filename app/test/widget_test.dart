import 'package:app/app.dart';
import 'package:flutter/riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app 启动渲染骨架', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    // M9.1 仅验证应用树可构建（空壳占位，无业务）。
    expect(find.byType(App), findsOneWidget);
  });
}
