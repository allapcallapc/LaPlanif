import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/ai_call_log.dart';
import 'package:laplanif/screens/ai_usage_screen.dart';
import 'package:laplanif/services/ai_call_activity.dart';
import 'package:laplanif/services/ai_call_log_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows an empty state with no logged calls', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AiUsageScreen(repository: AiCallLogRepository())));
    await tester.pumpAndSettle();

    expect(find.text('No AI calls yet.'), findsOneWidget);
  });

  testWidgets('lists successful and failed calls', (tester) async {
    final repository = AiCallLogRepository();
    await repository.add(
      AiCallLog(
        timestamp: DateTime(2026, 1, 1, 9, 5),
        storeName: 'IGA',
        model: 'claude-haiku-4-5-20251001',
        success: true,
        inputTokens: 1200,
        outputTokens: 300,
      ),
    );
    await repository.add(
      AiCallLog(
        timestamp: DateTime(2026, 1, 1, 9, 6),
        storeName: 'Metro',
        model: 'claude-haiku-4-5-20251001',
        success: false,
        errorMessage: 'AI API HTTP 500',
      ),
    );

    await tester.pumpWidget(MaterialApp(home: AiUsageScreen(repository: repository)));
    await tester.pumpAndSettle();

    expect(find.textContaining('IGA'), findsOneWidget);
    expect(find.textContaining('1200 in / 300 out tokens'), findsOneWidget);
    expect(find.textContaining('Metro'), findsOneWidget);
    expect(find.textContaining('AI API HTTP 500'), findsOneWidget);
  });

  testWidgets('expands a call with a page sample to reveal the scraped text', (tester) async {
    final repository = AiCallLogRepository();
    await repository.add(
      AiCallLog(
        timestamp: DateTime(2026, 1, 1, 9, 5),
        storeName: 'Maxi',
        model: 'gemini-3.5-flash-lite',
        success: true,
        inputTokens: 500,
        outputTokens: 13,
        pageSample: '2 page(s), avg 45 chars/page. Page 1: "Maxi - Page 1"',
      ),
    );

    await tester.pumpWidget(MaterialApp(home: AiUsageScreen(repository: repository)));
    await tester.pumpAndSettle();

    // Collapsed by default - the raw sample doesn't clutter the row until
    // asked for.
    expect(find.textContaining('Maxi - Page 1'), findsNothing);

    await tester.tap(find.textContaining('Maxi · gemini-3.5-flash-lite'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Maxi - Page 1'), findsOneWidget);
  });

  testWidgets('shows currently running calls above the history', (tester) async {
    final activity = ValueNotifier<List<AiInFlightCall>>([
      AiInFlightCall(id: 1, storeName: 'Maxi', model: 'gemini-3.6-flash', startedAt: DateTime(2026, 1, 1, 9, 0)),
    ]);

    // pumpAndSettle would never terminate: the running row's spinner is an
    // indeterminate CircularProgressIndicator that animates forever.
    await tester.pumpWidget(
      MaterialApp(home: AiUsageScreen(repository: AiCallLogRepository(), activity: activity)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Running now'), findsOneWidget);
    expect(find.textContaining('Maxi · gemini-3.6-flash'), findsOneWidget);
    expect(find.text('No AI calls yet.'), findsNothing);
  });

  testWidgets('drops a running call from the list once it finishes', (tester) async {
    final activity = ValueNotifier<List<AiInFlightCall>>([
      AiInFlightCall(id: 1, storeName: 'IGA', model: 'gemini-3.6-flash', startedAt: DateTime(2026, 1, 1, 9, 0)),
    ]);

    await tester.pumpWidget(
      MaterialApp(home: AiUsageScreen(repository: AiCallLogRepository(), activity: activity)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Running now'), findsOneWidget);

    activity.value = const [];
    await tester.pump();
    await tester.pump();

    expect(find.text('Running now'), findsNothing);
    expect(find.text('No AI calls yet.'), findsOneWidget);
  });

  testWidgets('reloads the persisted log when a running call finishes', (tester) async {
    final repository = AiCallLogRepository();
    final activity = ValueNotifier<List<AiInFlightCall>>([
      AiInFlightCall(id: 1, storeName: 'IGA', model: 'gemini-3.6-flash', startedAt: DateTime(2026, 1, 1, 9, 0)),
    ]);

    await tester.pumpWidget(
      MaterialApp(home: AiUsageScreen(repository: repository, activity: activity)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Running now'), findsOneWidget);

    // The call finishes: AiDealExtractionService persists the outcome and
    // then the in-flight notifier shrinks, same order as the real flow.
    await repository.add(
      AiCallLog(
        timestamp: DateTime(2026, 1, 1, 9, 1),
        storeName: 'IGA',
        model: 'gemini-3.6-flash',
        success: true,
        inputTokens: 500,
        outputTokens: 50,
      ),
    );
    activity.value = const [];
    await tester.pump();
    await tester.pump();

    // The finished call shows up here without leaving and reopening the
    // screen - _logs isn't stuck with whatever initState fetched.
    expect(find.text('Running now'), findsNothing);
    expect(find.textContaining('500 in / 50 out tokens'), findsOneWidget);
  });
}
