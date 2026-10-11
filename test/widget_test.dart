import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lockdown/main.dart';

void main() {
  testWidgets('HomeScreen smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our home screen shows up.
    expect(find.text('LockDown'), findsOneWidget);
    expect(find.text('Tap lock to unlock Sign Up'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
  });
}
