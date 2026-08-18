import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/services/ai_call_activity.dart';

void main() {
  tearDown(() {
    AiCallActivity.inFlight.value = const [];
  });

  test('start adds a call and finish removes it by id', () {
    final id = AiCallActivity.start(storeName: 'IGA', model: 'gemini-3.6-flash');

    expect(AiCallActivity.inFlight.value.length, 1);
    expect(AiCallActivity.inFlight.value.single.storeName, 'IGA');
    expect(AiCallActivity.inFlight.value.single.model, 'gemini-3.6-flash');

    AiCallActivity.finish(id);

    expect(AiCallActivity.inFlight.value, isEmpty);
  });

  test('tracks multiple concurrent calls independently', () {
    final idA = AiCallActivity.start(storeName: 'IGA', model: 'gemini-3.6-flash');
    final idB = AiCallActivity.start(storeName: 'Metro', model: 'gemini-3.6-flash');

    expect(AiCallActivity.inFlight.value.length, 2);

    AiCallActivity.finish(idA);

    expect(AiCallActivity.inFlight.value.length, 1);
    expect(AiCallActivity.inFlight.value.single.storeName, 'Metro');

    AiCallActivity.finish(idB);

    expect(AiCallActivity.inFlight.value, isEmpty);
  });
}
