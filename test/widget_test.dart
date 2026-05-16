import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:limitless_cloud/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('App starts correctly', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: LimitlessCloudApp()),
    );
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
