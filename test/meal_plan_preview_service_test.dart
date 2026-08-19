import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/services/ai_call_activity.dart';
import 'package:laplanif/services/ai_call_log_repository.dart';
import 'package:laplanif/services/meal_plan_preview_service.dart';
import 'package:laplanif/services/model_fallback_controller.dart';

http.Response _successResponse({
  int inputTokens = 100,
  int outputTokens = 50,
  required List<Map<String, dynamic>> slots,
}) {
  return http.Response(
    jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {
                'functionCall': {
                  'name': 'record_slot_previews',
                  'args': {'slots': slots},
                },
              },
            ],
            'role': 'model',
          },
        },
      ],
      'usageMetadata': {'promptTokenCount': inputTokens, 'candidatesTokenCount': outputTokens},
    }),
    200,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AiCallActivity.inFlight.value = const [];
  });

  const mealSlots = [
    MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5),
    MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4),
  ];

  const items = [
    DealItem(
      name: 'Chicken thighs',
      price: '3.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 1,
      preference: DealPreference.priority,
    ),
    DealItem(
      name: 'Ground beef',
      price: '5.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'Metro',
      pageIndex: 1,
      preference: DealPreference.excluded,
    ),
    DealItem(
      name: 'Firm tofu',
      price: '2.49\$',
      unit: '',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 2,
    ),
  ];

  test('parses one slot preview per meal slot, in order, and logs a successful call', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent',
      );
      expect(request.headers['x-goog-api-key'], 'test-key');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final tools = body['tools'] as List;
      expect(tools.length, 1);
      final declarations = (tools.single as Map)['functionDeclarations'] as List;
      expect((declarations.single as Map)['name'], 'record_slot_previews');

      // Excluded items are called out in the prompt rather than silently dropped.
      expect(request.body, contains('Ground beef'));
      expect(request.body, contains('Excluded'));

      // Chicken thighs (pageIndex 1) is a cover-page item and gets flagged
      // as such; Firm tofu (pageIndex 2) is not.
      expect(request.body, contains('Chicken thighs (IGA, Protein, 3.99\$/lb) [COVER DEAL]'));
      expect(request.body, isNot(contains('Firm tofu (IGA, Protein, 2.49\$) [COVER DEAL]')));

      return _successResponse(
        slots: [
          {
            'anchorItems': [
              {'name': 'Chicken thighs', 'store': 'IGA'},
            ],
            'note': 'Big-batch chicken thigh stir-fry.',
          },
          {
            'anchorItems': [
              {'name': 'Firm tofu', 'store': 'IGA'},
            ],
            'note': 'Big-batch tofu curry.',
          },
        ],
      );
    });

    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    final preview = await service.previewMealPlan(
      apiKey: 'test-key',
      mealSlots: mealSlots,
      portionsPerMeal: 3,
      items: items,
    );

    expect(preview.slots.length, 2);
    expect(preview.slots[0].mealType, MealType.lunch);
    expect(preview.slots[0].protein, 'meat');
    expect(preview.slots[0].totalPortionsNeeded, 15);
    expect(preview.slots[0].anchorItems.single.name, 'Chicken thighs');
    expect(preview.slots[0].anchorItems.single.store, 'IGA');
    expect(preview.slots[0].note, 'Big-batch chicken thigh stir-fry.');

    expect(preview.slots[1].mealType, MealType.supper);
    expect(preview.slots[1].totalPortionsNeeded, 12);

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs[0].success, isTrue);
    expect(logs[0].model, 'gemini-3.5-flash-lite');
    expect(logs[0].inputTokens, 100);
    expect(logs[0].outputTokens, 50);
  });

  test('tells the AI which anchors are already used elsewhere in the plan', () async {
    final client = MockClient((request) async {
      expect(request.body, contains('Chicken thighs (IGA)'));
      expect(request.body, contains('already used as anchors elsewhere'));

      return _successResponse(
        slots: [
          {
            'anchorItems': [
              {'name': 'Firm tofu', 'store': 'IGA'},
            ],
            'note': 'Big-batch tofu curry.',
          },
        ],
      );
    });

    final service = MealPlanPreviewService(client: client, logRepository: AiCallLogRepository());

    await service.previewMealPlan(
      apiKey: 'test-key',
      mealSlots: const [MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4)],
      portionsPerMeal: 3,
      items: items,
      alreadyUsedAnchors: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
    );
  });

  test('omitting alreadyUsedAnchors sends an empty list, not a missing section', () async {
    final client = MockClient((request) async {
      expect(request.body, contains('already used as anchors elsewhere'));
      return _successResponse(
        slots: [
          {
            'anchorItems': [
              {'name': 'Firm tofu', 'store': 'IGA'},
            ],
            'note': 'note',
          },
        ],
      );
    });

    final service = MealPlanPreviewService(client: client, logRepository: AiCallLogRepository());

    await service.previewMealPlan(
      apiKey: 'test-key',
      mealSlots: const [MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4)],
      portionsPerMeal: 3,
      items: items,
    );
  });

  test('throws and logs a failure when the response has the wrong number of slot previews', () async {
    final client = MockClient(
      (request) async => _successResponse(
        slots: [
          {
            'anchorItems': [
              {'name': 'Chicken thighs', 'store': 'IGA'},
            ],
            'note': 'note',
          },
        ],
      ),
    );

    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsException,
    );

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs[0].success, isFalse);
    expect(logs[0].errorMessage, contains('expected 2 slot previews, got 1'));
  });

  test('throws RateLimitedException and logs a failure on HTTP 429', () async {
    final client = MockClient((request) async => http.Response('', 429));
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsA(isA<RateLimitedException>()),
    );

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs[0].success, isFalse);
  });

  test('throws and logs a failure when the HTTP call fails outright', () async {
    final client = MockClient((request) async => http.Response('nope', 500));
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsException,
    );

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs[0].success, isFalse);
    expect(logs[0].errorMessage, contains('HTTP 500'));
  });

  test('throws and logs a failure when the connection itself fails', () async {
    final client = MockClient((request) async => throw Exception('network down'));
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsException,
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('Could not reach the AI API'));
  });

  test('throws and logs a failure when the response body is not valid JSON', () async {
    final client = MockClient((request) async => http.Response('not json', 200));
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsException,
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('Invalid JSON'));
  });

  test('throws and logs a failure when no candidates are returned', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': <dynamic>[],
          'promptFeedback': {'blockReason': 'SAFETY'},
          'usageMetadata': {'promptTokenCount': 8, 'candidatesTokenCount': 0},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsA(anything),
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no candidates returned (blockReason: SAFETY)'));
  });

  test('throws and logs a failure when a candidate has no content', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': [
            {'finishReason': 'MAX_TOKENS'},
          ],
          'usageMetadata': {'promptTokenCount': 8, 'candidatesTokenCount': 0},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsA(anything),
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no content in response (finishReason: MAX_TOKENS)'));
  });

  test('throws and logs a failure when the response has no functionCall part', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Sorry, nothing found.'},
                ],
                'role': 'model',
              },
            },
          ],
          'usageMetadata': {'promptTokenCount': 10, 'candidatesTokenCount': 5},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    await expectLater(
      service.previewMealPlan(apiKey: 'test-key', mealSlots: mealSlots, portionsPerMeal: 3, items: items),
      throwsA(anything),
    );

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no functionCall in response'));
    expect(log.inputTokens, 10);
    expect(log.outputTokens, 5);
  });
}
