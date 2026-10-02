import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview/main.dart';

void main() {
  testWidgets('renders the NES web view application', (tester) async {
    await tester.pumpWidget(const NesWebViewApp(home: SizedBox()));

    expect(find.byType(SizedBox), findsOneWidget);
  });
}
