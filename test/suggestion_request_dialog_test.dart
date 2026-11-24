import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/widgets/suggestion_request_dialog.dart';

void main() {
  String? result;
  var closed = false;

  Future<void> pumpAndOpen(WidgetTester tester) async {
    result = null;
    closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showSuggestionRequestDialog(
                  context,
                  title: 'Suggest another vegetable',
                  examples: const ['From the pantry', 'A red vegetable'],
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Suggest with nothing typed gives an empty request', (tester) async {
    await pumpAndOpen(tester);
    expect(find.text('Suggest another vegetable'), findsOneWidget);
    expect(find.text('Anything specific? (optional)'), findsOneWidget);

    await tester.tap(find.text('Suggest'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, '');
  });

  testWidgets('an example fills the field, and the typed request is trimmed', (tester) async {
    await pumpAndOpen(tester);

    await tester.tap(find.text('A red vegetable'));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'A red vegetable'), findsOneWidget);
    await tester.tap(find.text('Suggest'));
    await tester.pumpAndSettle();
    expect(result, 'A red vegetable');

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  no peppers  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, 'no peppers');
  });

  testWidgets('Cancel gives null', (tester) async {
    await pumpAndOpen(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets('the confirm button can be relabelled, e.g. for a recipe', (tester) async {
    String? value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async => value = await showSuggestionRequestDialog(
                context,
                title: 'Regenerate the recipe',
                examples: const ['Slow cooker'],
                actionLabel: 'Generate',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Suggest'), findsNothing);
    expect(find.text('e.g. slow cooker'), findsOneWidget);
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(value, '');
  });
}
