import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/ai_call_log.dart';
import 'package:laplanif/services/ai_call_log_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('starts empty', () async {
    final repo = AiCallLogRepository();
    expect(await repo.loadAll(), isEmpty);
  });

  test('stores newest entries first', () async {
    final repo = AiCallLogRepository();
    await repo.add(
      AiCallLog(timestamp: DateTime(2026, 1, 1), storeName: 'IGA', model: 'm', success: true),
    );
    await repo.add(
      AiCallLog(timestamp: DateTime(2026, 1, 2), storeName: 'Metro', model: 'm', success: false),
    );

    final logs = await repo.loadAll();
    expect(logs.length, 2);
    expect(logs[0].storeName, 'Metro');
    expect(logs[1].storeName, 'IGA');
  });

  test('round-trips every field through JSON', () async {
    final repo = AiCallLogRepository();
    await repo.add(
      AiCallLog(
        timestamp: DateTime(2026, 1, 1, 10, 30),
        storeName: 'IGA',
        model: 'claude-haiku-4-5-20251001',
        success: false,
        inputTokens: 123,
        outputTokens: 45,
        errorMessage: 'boom',
      ),
    );

    final log = (await repo.loadAll()).single;
    expect(log.timestamp, DateTime(2026, 1, 1, 10, 30));
    expect(log.storeName, 'IGA');
    expect(log.model, 'claude-haiku-4-5-20251001');
    expect(log.success, isFalse);
    expect(log.inputTokens, 123);
    expect(log.outputTokens, 45);
    expect(log.errorMessage, 'boom');
  });
}
