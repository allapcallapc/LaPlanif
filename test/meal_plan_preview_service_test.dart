import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/models/meal_history.dart';
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
  String? instructionCheck,
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
                  'args': {if (instructionCheck != null) 'instructionCheck': instructionCheck, 'slots': slots},
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

  test('includes non-empty dietaryNotes as standing planning instructions', () async {
    final client = MockClient((request) async {
      expect(request.body, contains('Standing planning instructions - follow these across every slot:'));
      expect(request.body, contains('No more than 2 days of fish per week.'));

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
      dietaryNotes: 'No more than 2 days of fish per week.',
    );
  });

  test('makes the AI check standing instructions against every slot before picking anchors', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final params =
          ((body['tools'] as List).single['functionDeclarations'] as List).single['parameters'] as Map<String, dynamic>;
      // instructionCheck must be required and come before slots, so the
      // model reasons through e.g. "max 2 days of fish" vs a count=5 slot
      // before it commits to anchors.
      expect(params['required'], contains('instructionCheck'));
      expect(params['propertyOrdering'], ['instructionCheck', 'slots']);

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
      dietaryNotes: 'No more than 2 days of fish per week.',
    );
  });

  test('tells a single-slot regenerate about the other slots\' counts for frequency limits', () async {
    final client = MockClient((request) async {
      expect(
        request.body,
        contains(
          'Other slots already in this plan, not part of this call - their anchors are fixed, but count their '
          'days toward any frequency limit in the standing instructions:\\n'
          '- supper, protein=meat, count=2 days, anchors: Salmon fillet (IGA)',
        ),
      );
      return _successResponse(
        slots: [
          {
            'anchorItems': [
              {'name': 'Chicken thighs', 'store': 'IGA'},
            ],
            'note': 'note',
          },
        ],
      );
    });
    final service = MealPlanPreviewService(client: client, logRepository: AiCallLogRepository());

    await service.previewMealPlan(
      apiKey: 'test-key',
      mealSlots: const [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      portionsPerMeal: 3,
      items: items,
      dietaryNotes: 'No more than 2 days of fish.',
      otherSlots: const [
        MealSlotPreview(
          mealType: MealType.supper,
          protein: 'meat',
          count: 2,
          portionsPerMeal: 3,
          anchorItems: [AnchorItem(name: 'Salmon fillet', store: 'IGA')],
          note: '',
        ),
      ],
    );
  });

  test('parses a response that includes instructionCheck and keeps it in the call log', () async {
    final client = MockClient(
      (request) async => _successResponse(
        instructionCheck: 'No fish over 2 days: slot 1 (count=4) uses tofu, no fish.',
        slots: [
          {
            'anchorItems': [
              {'name': 'Firm tofu', 'store': 'IGA'},
            ],
            'note': 'Tofu stir-fry.',
          },
        ],
      ),
    );
    final logRepository = AiCallLogRepository();
    final service = MealPlanPreviewService(client: client, logRepository: logRepository);

    final preview = await service.previewMealPlan(
      apiKey: 'test-key',
      mealSlots: const [MealSlot(id: 'supper-tofu', mealType: MealType.supper, protein: 'tofu', count: 4)],
      portionsPerMeal: 3,
      items: items,
      dietaryNotes: 'No more than 2 days of fish.',
    );

    expect(preview.slots.single.anchorItems.single.name, 'Firm tofu');
    final logs = await logRepository.loadAll();
    expect(logs.single.details, 'Instruction check: No fish over 2 days: slot 1 (count=4) uses tofu, no fish.');
  });

  test('omits the standing-instructions section when dietaryNotes is empty', () async {
    final client = MockClient((request) async {
      // The system prompt always mentions "Standing planning instructions" in
      // the abstract - only the concrete per-request section (with its
      // trailing colon) should be absent when there's nothing to say.
      expect(request.body, isNot(contains('Standing planning instructions - follow these across every slot:')));

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

  test('includes recently used recipes and their deal items as a soft diversity hint', () async {
    final client = MockClient((request) async {
      expect(request.body, contains('Recently used'));
      expect(request.body, contains('General Tao Chicken'));
      expect(request.body, contains('Chicken thighs (IGA)'));

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
      recentlyUsed: const [
        RecentHistoryItem(
          recipeName: 'General Tao Chicken',
          dealItemsUsed: [AnchorItem(name: 'Chicken thighs', store: 'IGA')],
        ),
      ],
    );
  });

  test('omitting recentlyUsed sends an empty list, not a missing section', () async {
    final client = MockClient((request) async {
      expect(request.body, contains('Recently used'));
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

  test('requires a carb for every slot, allowing pantry staples, and parses them as pantry carbs', () async {
    final client = MockClient((request) async {
      expect(request.body, contains('every slot must have exactly one carb anchor'));
      expect(request.body, contains('quinoa'));
      expect(request.body, contains('"pantry"'));
      expect(request.body, contains('"role"'));
      expect(request.body, contains('a protein such as tofu'));
      return _successResponse(
        slots: [
          {
            'anchorItems': [
              {'name': 'Chicken thighs', 'store': 'IGA', 'pantry': false, 'role': 'protein'},
              {'name': 'Quinoa', 'store': 'Pantry', 'pantry': true, 'role': 'carb'},
            ],
            'note': 'Chicken with quinoa.',
          },
          {
            'anchorItems': [
              {'name': 'Firm tofu', 'store': 'IGA', 'pantry': false, 'role': 'protein'},
              // No pantry flag, but no store either - still a pantry carb.
              {'name': 'Couscous', 'store': ''},
            ],
            'note': 'Tofu with couscous.',
          },
        ],
      );
    });
    final service = MealPlanPreviewService(client: client, logRepository: AiCallLogRepository());

    final preview = await service.previewMealPlan(
      apiKey: 'test-key',
      mealSlots: mealSlots,
      portionsPerMeal: 3,
      items: items,
    );

    final lunch = preview.slots[0].anchorItems;
    expect(lunch[0].isPantry, isFalse);
    expect(lunch[0].isCarb, isFalse);
    expect(lunch[0].role, AnchorRole.protein);
    expect(lunch[1].isCarb, isTrue);
    expect(preview.slots[1].anchorItems[0].isCarb, isFalse);
    expect(preview.slots[1].anchorItems[1].isCarb, isTrue);
    expect(lunch[1].isPantry, isTrue);
    expect(lunch[1].store, AnchorItem.pantryStore);
    final supper = preview.slots[1].anchorItems;
    expect(supper[1].name, 'Couscous');
    expect(supper[1].isPantry, isTrue);
    expect(supper[1].store, AnchorItem.pantryStore);
  });

  test('a pantry anchor round-trips through JSON, and old JSON without the flag is a deal item', () {
    const quinoa = AnchorItem.pantry('Quinoa');
    expect(AnchorItem.fromJson(quinoa.toJson()).isPantry, isTrue);
    expect(const AnchorItem(name: 'Tofu', store: 'IGA').toJson().containsKey('pantry'), isFalse);
    expect(AnchorItem.fromJson({'name': 'Tofu', 'store': 'IGA'}).isPantry, isFalse);
  });

  test('a deal item marked as the carb is parsed as one and round-trips through JSON', () async {
    final client = MockClient(
      (request) async => _successResponse(
        slots: [
          {
            'anchorItems': [
              {'name': 'Chicken thighs', 'store': 'IGA', 'pantry': false, 'role': 'protein'},
              {'name': 'Spaghetti', 'store': 'IGA', 'pantry': false, 'role': 'carb'},
            ],
            'note': 'Chicken pasta.',
          },
        ],
      ),
    );
    final service = MealPlanPreviewService(client: client, logRepository: AiCallLogRepository());

    final preview = await service.previewMealPlan(
      apiKey: 'test-key',
      mealSlots: const [MealSlot(id: 'lunch-meat', mealType: MealType.lunch, protein: 'meat', count: 5)],
      portionsPerMeal: 3,
      items: items,
    );

    final spaghetti = preview.slots.single.anchorItems[1];
    expect(spaghetti.isCarb, isTrue);
    expect(spaghetti.isPantry, isFalse);
    final restored = AnchorItem.fromJson(spaghetti.toJson());
    expect(restored.isCarb, isTrue);
    expect(restored.isPantry, isFalse);
    expect(AnchorItem.fromJson(const AnchorItem.pantry('Rice').toJson()).isCarb, isTrue);
  });

  test('an item\'s role round-trips through JSON, and older saved items still load', () {
    const veg = AnchorItem(name: 'Brocoli', store: 'IGA', role: AnchorRole.vegetable);
    expect(AnchorItem.fromJson(veg.toJson()).role, AnchorRole.vegetable);
    // Saved before roles: no role at all, or the earlier `carb` flag.
    expect(AnchorItem.fromJson({'name': 'Tofu', 'store': 'IGA'}).role, isNull);
    expect(AnchorItem.fromJson({'name': 'Riz', 'store': 'Maxi', 'carb': true}).role, AnchorRole.carb);
    // Plain deal items (e.g. in saved history) are written exactly as before.
    expect(const AnchorItem(name: 'Tofu', store: 'IGA').toJson(), {'name': 'Tofu', 'store': 'IGA'});
  });

  group('suggestReplacement', () {
    http.Response replacementResponse(Map<String, dynamic> args) => http.Response(
      jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {
                  'functionCall': {'name': 'record_replacement', 'args': args},
                },
              ],
            },
          },
        ],
        'usageMetadata': {'promptTokenCount': 40, 'candidatesTokenCount': 5},
      }),
      200,
    );

    const slot = MealSlotPreview(
      mealType: MealType.lunch,
      protein: 'meat',
      count: 3,
      portionsPerMeal: 2,
      anchorItems: [
        AnchorItem(name: 'Chicken thighs', store: 'IGA', role: AnchorRole.protein),
        AnchorItem.pantry('Basmati rice'),
      ],
      note: 'Chicken and rice.',
    );

    test('asks for one replacement playing the same role and returns the deal it names', () async {
      late String body;
      final client = MockClient((request) async {
        body = request.body;
        return replacementResponse({'name': 'Ground beef', 'store': 'Metro', 'pantry': false});
      });
      final logRepository = AiCallLogRepository();
      final service = MealPlanPreviewService(client: client, logRepository: logRepository);

      final replacement = await service.suggestReplacement(
        apiKey: 'test-key',
        slot: slot,
        replacing: slot.anchorItems.first,
        role: AnchorRole.protein,
        items: items,
        alreadyUsedAnchors: const [AnchorItem(name: 'Firm tofu', store: 'IGA')],
        dietaryNotes: 'No pork.',
      );

      expect(replacement.name, 'Ground beef');
      expect(replacement.store, 'Metro');
      expect(replacement.role, AnchorRole.protein);
      expect(replacement.isPantry, isFalse);
      expect(body, contains('record_replacement'));
      expect(body, contains('Ingredient to replace (role: protein): Chicken thighs (IGA)'));
      // The meal's other ingredient is given as context, not as the one to replace.
      expect(body, contains('- Basmati rice (Pantry)'));
      expect(body, contains('already used by other meals'));
      expect(body, contains('Firm tofu (IGA)'));
      expect(body, contains('No pork.'));
      final log = (await logRepository.loadAll()).single;
      expect(log.success, isTrue);
      expect(log.inputTokens, 40);
    });

    test('returns an ingredient not on sale as a pantry item with the asked role', () async {
      final client = MockClient(
        (request) async => replacementResponse({'name': 'Couscous', 'store': 'Pantry', 'pantry': true}),
      );
      final service = MealPlanPreviewService(client: client, logRepository: AiCallLogRepository());

      final replacement = await service.suggestReplacement(
        apiKey: 'test-key',
        slot: slot,
        replacing: slot.anchorItems[1],
        role: AnchorRole.carb,
        items: items,
      );

      expect(replacement.name, 'Couscous');
      expect(replacement.isPantry, isTrue);
      expect(replacement.role, AnchorRole.carb);
    });

    test('throws and logs a failure when the response has no usable answer', () async {
      for (final response in [
        replacementResponse({'name': '  ', 'store': 'IGA', 'pantry': false}),
        http.Response(jsonEncode({'candidates': []}), 200),
        http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'no call'},
                  ],
                },
              },
            ],
          }),
          200,
        ),
      ]) {
        final logRepository = AiCallLogRepository();
        final service = MealPlanPreviewService(client: MockClient((request) async => response), logRepository: logRepository);
        await expectLater(
          service.suggestReplacement(
            apiKey: 'test-key',
            slot: slot,
            replacing: slot.anchorItems.first,
            role: AnchorRole.protein,
            items: items,
          ),
          throwsException,
        );
        expect((await logRepository.loadAll()).last.success, isFalse);
      }
    });

    test('throws RateLimitedException on HTTP 429', () async {
      final service = MealPlanPreviewService(
        client: MockClient((request) async => http.Response('', 429)),
        logRepository: AiCallLogRepository(),
      );
      await expectLater(
        service.suggestReplacement(
          apiKey: 'test-key',
          slot: slot,
          replacing: slot.anchorItems.first,
          role: AnchorRole.protein,
          items: items,
        ),
        throwsA(isA<RateLimitedException>()),
      );
    });
  });

  test('an ingredient not on sale keeps a non-carb role through JSON', () {
    const custom = AnchorItem.pantry('Chicken breast', role: AnchorRole.protein);
    final restored = AnchorItem.fromJson(custom.toJson());
    expect(restored.isPantry, isTrue);
    expect(restored.role, AnchorRole.protein);
    // A pantry carb is written as before, without a role.
    expect(const AnchorItem.pantry('Rice').toJson(), {'name': 'Rice', 'store': 'Pantry', 'pantry': true});
  });
}
