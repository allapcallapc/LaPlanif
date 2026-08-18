import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/main.dart';

void main() {
  testWidgets('shows the construction message', (WidgetTester tester) async {
    await tester.pumpWidget(const LaPlanifApp());

    expect(find.text('LaPlanif is under construction'), findsOneWidget);
    expect(find.byIcon(Icons.construction), findsOneWidget);
  });
}
