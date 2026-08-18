import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/ai_call_log.dart';
import 'package:laplanif/screens/ai_usage_screen.dart';
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
}
