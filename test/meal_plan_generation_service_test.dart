import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/services/ai_call_activity.dart';
import 'package:laplanif/services/ai_call_log_repository.dart';
import 'package:laplanif/services/meal_plan_generation_service.dart';
import 'package:laplanif/services/model_fallback_controller.dart';

http.Response _researchResponse({int inputTokens = 200, int outputTokens = 150, required String text}) {
  return http.Response(
    jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': text},
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

http.Response _extractionResponse({
  int inputTokens = 300,
  int outputTokens = 250,
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
                  'name': 'record_meal_components',
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

Map<String, dynamic> _rawComponent({
  required String type,
  required String name,
  String recipeUrl = '',
  List<Map<String, String>> ingredients = const [],
  List<String> instructions = const [],
  String note = '',
  bool usesWeeklyDeal = false,
  List<Map<String, String>> dealItems = const [],
}) => {
  'type': type,
  'name': name,
  'recipeUrl': recipeUrl,
  'ingredients': ingredients,
  'instructions': instructions,
  'note': note,
  'usesWeeklyDeal': usesWeeklyDeal,
  'dealItems': dealItems,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AiCallActivity.inFlight.value = const [];
  });

  const slots = [
    MealSlotPreview(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 5,
      portionsPerMeal: 3,
      anchorItems: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
      note: 'Big-batch chicken thigh stir-fry.',
    ),
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
      name: 'Broccoli',
      price: '2.49\$',
      unit: '',
      category: DealCategory.vegetables,
      storeName: 'IGA',
      pageIndex: 2,
    ),
  ];

  test('runs a research call then an extraction call, parses components, and logs both phases', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent',
      );
      expect(request.headers['x-goog-api-key'], 'test-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;

      if (callCount == 1) {
        // Phase 1: grounded research, no function-calling tools.
        final tools = body['tools'] as List;
        expect((tools.single as Map).containsKey('google_search'), isTrue);
        expect(body.containsKey('toolConfig'), isFalse);
        expect(request.body, contains('Chicken thighs (IGA)'));
        return _researchResponse(
          text:
              'Slot 1 protein: verified link https://example.com/chicken-stir-fry. '
              'The recipe already includes rice as an ingredient (carb covered). '
              'Vegetable not covered - propose steamed broccoli as a simple side, using the Broccoli deal item at IGA.',
        );
      }

      // Phase 2: structured extraction.
      final tools = body['tools'] as List;
      final declarations = (tools.single as Map)['functionDeclarations'] as List;
      expect((declarations.single as Map)['name'], 'record_meal_components');
      expect(request.body, contains('Research notes from the search step'));
      expect(request.body, contains('already includes rice'));

      return _extractionResponse(
        slots: [
          {
            'protein': _rawComponent(
              type: 'link',
              name: 'Big-batch chicken thigh stir-fry',
              recipeUrl: 'https://example.com/chicken-stir-fry',
              usesWeeklyDeal: true,
              dealItems: [
                {'name': 'Chicken thighs', 'store': 'IGA'},
              ],
            ),
            'carb': _rawComponent(
              type: 'covered_by_protein',
              name: 'Rice (included in the stir-fry recipe)',
              recipeUrl: 'https://example.com/chicken-stir-fry',
            ),
            'vegetable': _rawComponent(
              type: 'simple_side',
              name: 'Steamed broccoli',
              note: 'Steam 5 min, toss with butter.',
              usesWeeklyDeal: true,
              dealItems: [
                {'name': 'Broccoli', 'store': 'IGA'},
              ],
            ),
          },
        ],
      );
    });

    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    final plan = await service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items);

    expect(callCount, 2);
    expect(plan.slots.length, 1);
    final slot = plan.slots.single;
    expect(slot.mealType, MealType.lunch);
    expect(slot.protein, 'meat');
    expect(slot.totalPortionsNeeded, 15);

    expect(slot.proteinComponent.type, MealComponentType.link);
    expect(slot.proteinComponent.name, 'Big-batch chicken thigh stir-fry');
    expect(slot.proteinComponent.recipeUrl, 'https://example.com/chicken-stir-fry');
    expect(slot.proteinComponent.usesWeeklyDeal, isTrue);
    expect(slot.proteinComponent.dealItems.single.name, 'Chicken thighs');

    expect(slot.carbComponent.type, MealComponentType.coveredByProtein);
    expect(slot.carbComponent.recipeUrl, 'https://example.com/chicken-stir-fry');

    expect(slot.vegetableComponent.type, MealComponentType.simpleSide);
    expect(slot.vegetableComponent.note, 'Steam 5 min, toss with butter.');
    expect(slot.vegetableComponent.recipeUrl, isNull);
    expect(slot.vegetableComponent.dealItems.single.store, 'IGA');

    // AiCallLogRepository stores newest first, so the extraction call (made
    // second) comes back at index 0.
    final logs = await logRepository.loadAll();
    expect(logs.length, 2);
    expect(logs[0].storeName, 'Meal plan generation (extraction)');
    expect(logs[0].success, isTrue);
    expect(logs[0].inputTokens, 300);
    expect(logs[1].storeName, 'Meal plan generation (research)');
    expect(logs[1].success, isTrue);
    expect(logs[1].inputTokens, 200);
  });

  test('empty recipeUrl parses to null and blank ingredients/instructions parse to empty lists', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      if (callCount == 1) return _researchResponse(text: 'No verified links found for any component.');
      return _extractionResponse(
        slots: [
          {
            'protein': _rawComponent(type: 'ai_recipe', name: 'Chicken curry'),
            'carb': _rawComponent(type: 'simple_side', name: 'Rice', note: 'Steamed, plain.'),
            'vegetable': _rawComponent(type: 'simple_side', name: 'Broccoli', note: 'Steamed.'),
          },
        ],
      );
    });

    final service = MealPlanGenerationService(client: client, logRepository: AiCallLogRepository());
    final plan = await service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items);

    expect(plan.slots.single.proteinComponent.recipeUrl, isNull);
    expect(plan.slots.single.proteinComponent.ingredients, isEmpty);
    expect(plan.slots.single.proteinComponent.instructions, isEmpty);
  });

  test('throws and logs a research-phase failure on HTTP 429', () async {
    final client = MockClient((request) async => http.Response('', 429));
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(
      service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items),
      throwsA(isA<RateLimitedException>()),
    );

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs.single.storeName, 'Meal plan generation (research)');
    expect(logs.single.success, isFalse);
  });

  test('throws and logs an extraction-phase failure on HTTP 429 after a successful research call', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      if (callCount == 1) return _researchResponse(text: 'Research notes.');
      return http.Response('', 429);
    });
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(
      service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items),
      throwsA(isA<RateLimitedException>()),
    );

    final logs = await logRepository.loadAll();
    expect(logs.length, 2);
    expect(logs[0].storeName, 'Meal plan generation (extraction)');
    expect(logs[0].success, isFalse);
    expect(logs[1].success, isTrue);
  });

  test('throws and logs a failure when the research call returns no text', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {'parts': <dynamic>[], 'role': 'model'},
            },
          ],
          'usageMetadata': {'promptTokenCount': 5, 'candidatesTokenCount': 0},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final logs = await logRepository.loadAll();
    expect(logs.length, 1);
    expect(logs.single.success, isFalse);
  });

  test('throws and logs an extraction failure when the response has the wrong number of slots', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      if (callCount == 1) return _researchResponse(text: 'Research notes.');
      return _extractionResponse(slots: const []);
    });
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final logs = await logRepository.loadAll();
    expect(logs.length, 2);
    expect(logs[0].success, isFalse);
    expect(logs[0].errorMessage, contains('expected 1 generated slots, got 0'));
  });

  test('throws and logs a failure when the connection itself fails on the research call', () async {
    final client = MockClient((request) async => throw Exception('network down'));
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final log = (await logRepository.loadAll()).single;
    expect(log.storeName, 'Meal plan generation (research)');
    expect(log.errorMessage, contains('Could not reach the AI API'));
  });

  test('throws and logs a research-phase failure on a generic non-200, non-429 HTTP status', () async {
    final client = MockClient((request) async => http.Response('nope', 500));
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final log = (await logRepository.loadAll()).single;
    expect(log.storeName, 'Meal plan generation (research)');
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('HTTP 500'));
  });

  test('throws and logs a research-phase failure when the response body is not valid JSON', () async {
    final client = MockClient((request) async => http.Response('not json', 200));
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('Invalid JSON'));
  });

  test('throws and logs a research-phase failure when no candidates are returned, citing the block reason', () async {
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
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no candidates returned (blockReason: SAFETY)'));
  });

  test('throws and logs a research-phase failure when a candidate has no content, citing the finish reason', () async {
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
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final log = (await logRepository.loadAll()).single;
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no content in response (finishReason: MAX_TOKENS)'));
  });

  test('throws and logs a research-phase failure when the response has content but no parts', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {'role': 'model'},
            },
          ],
          'usageMetadata': {'promptTokenCount': 8, 'candidatesTokenCount': 0},
        }),
        200,
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final log = (await logRepository.loadAll()).single;
    expect(log.storeName, 'Meal plan generation (research)');
    expect(log.success, isFalse);
    expect(log.errorMessage, contains('no content in response'));
  });

  test('throws and logs an extraction failure when the response has content but no parts', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      if (callCount == 1) return _researchResponse(text: 'Research notes.');
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {'role': 'model'},
            },
          ],
          'usageMetadata': {'promptTokenCount': 8, 'candidatesTokenCount': 0},
        }),
        200,
      );
    });
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final logs = await logRepository.loadAll();
    expect(logs[0].storeName, 'Meal plan generation (extraction)');
    expect(logs[0].success, isFalse);
    expect(logs[0].errorMessage, contains('no content in response'));
  });

  test('throws and logs an extraction failure when the response has no functionCall part', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      if (callCount == 1) return _researchResponse(text: 'Research notes.');
      return http.Response(
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
      );
    });
    final logRepository = AiCallLogRepository();
    final service = MealPlanGenerationService(client: client, logRepository: logRepository);

    await expectLater(service.generateMealPlan(apiKey: 'test-key', slots: slots, items: items), throwsException);

    final logs = await logRepository.loadAll();
    expect(logs[0].storeName, 'Meal plan generation (extraction)');
    expect(logs[0].success, isFalse);
    expect(logs[0].errorMessage, contains('no functionCall in response'));
  });
}
