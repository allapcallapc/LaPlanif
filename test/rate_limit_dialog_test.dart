import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/services/model_fallback_controller.dart';
import 'package:laplanif/widgets/rate_limit_dialog.dart';

void main() {
  Future<RateLimitChoice?> pumpAndOpen(
    WidgetTester tester, {
    required String currentModel,
    String? nextModel,
  }) async {
    RateLimitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showRateLimitDialog(context, currentModel: currentModel, nextModel: nextModel);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('offers only a same-model retry when there is no next model', (tester) async {
    await pumpAndOpen(tester, currentModel: 'gemini-a');

    expect(find.text('gemini-a is still rate limited. Try again?'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry gemini-a'), findsOneWidget);
    expect(find.text('Try gemini-a'), findsNothing);
  });

  testWidgets('returns retrySame when the retry button is tapped', (tester) async {
    RateLimitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showRateLimitDialog(context, currentModel: 'gemini-a');
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Retry gemini-a'));
    await tester.pumpAndSettle();

    expect(result, RateLimitChoice.retrySame);
  });

  testWidgets('offers a next-model choice and returns nextModel when tapped', (tester) async {
    RateLimitChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showRateLimitDialog(context, currentModel: 'gemini-a', nextModel: 'gemini-b');
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.text('gemini-a is still rate limited. Retry it, or try gemini-b instead?'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Try gemini-b'));
    await tester.pumpAndSettle();

    expect(result, RateLimitChoice.nextModel);
  });
}
