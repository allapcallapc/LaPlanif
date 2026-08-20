import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_call_log.dart';
import '../models/deal_item.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';
import '../utils/error_formatting.dart';
import 'ai_call_activity.dart';
import 'ai_call_log_repository.dart';
import 'ai_config_repository.dart';
import 'model_fallback_controller.dart';

/// Turns confirmed [MealSlotPreview]s into full meals - protein, carb and
/// vegetable components - using the Google AI (Gemini) API.
///
/// Two calls are made per invocation, since links are preferred over
/// AI-authored recipes and a real search capability (not just the model's
/// memory) is needed to avoid hallucinated URLs:
///
/// 1. A grounded research call (Google Search tool) that looks up and
///    verifies real recipe links for each slot's protein/carb/vegetable, and
///    checks whether the protein's recipe already explicitly covers the carb
///    and/or vegetable. This tries [groundingModels] in order rather than
///    the caller's chosen [model] - Search grounding quota isn't provisioned
///    for every model family (newer/preview families in particular often
///    have none at all on the free tier, failing every grounded call
///    outright), so the research step needs its own list of models actually
///    known to carry a Search grounding allowance. Configurable separately
///    from the general model list in Config, for exactly that reason.
/// 2. A structured extraction call (function calling) that converts those
///    research notes into the typed component format, without doing any
///    search itself - it may only reuse URLs the research call already
///    found, never invent new ones. This has no grounding requirement, so it
///    uses the caller's chosen [model] like any other call in the app.
class MealPlanGenerationService {
  MealPlanGenerationService({
    http.Client? client,
    String? model,
    List<String>? groundingModels,
    AiCallLogRepository? logRepository,
  }) : model = model ?? AiConfigRepository.defaultModels.first,
       groundingModels = groundingModels ?? AiConfigRepository.defaultGroundingModels,
       _client = client ?? http.Client(),
       _logRepository = logRepository ?? AiCallLogRepository(),
       assert(
         (groundingModels ?? AiConfigRepository.defaultGroundingModels).isNotEmpty,
         'groundingModels must not be empty',
       );

  static const _apiBase = 'https://generativelanguage.googleapis.com/v1beta/models';
  static const _logStoreName = 'Meal plan generation';

  final http.Client _client;
  final AiCallLogRepository _logRepository;
  final String model;

  /// Models to try, in order, for the grounded research call. Defaults to
  /// [AiConfigRepository.defaultGroundingModels] when not overridden, and can
  /// be overridden per call via [generateMealPlan]'s own `groundingModels`
  /// parameter (e.g. from a value loaded via
  /// [AiConfigRepository.loadGroundingModels]).
  final List<String> groundingModels;

  Future<MealPlanFull> generateMealPlan({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    String dietaryNotes = '',
    String? model,
    List<String>? groundingModels,
  }) async {
    final effectiveModel = model ?? this.model;
    final effectiveGroundingModels = groundingModels ?? this.groundingModels;
    final activityId = AiCallActivity.start(storeName: _logStoreName, model: effectiveModel);
    try {
      final research = await _research(
        apiKey: apiKey,
        slots: slots,
        items: items,
        dietaryNotes: dietaryNotes,
        groundingModels: effectiveGroundingModels,
      );
      return await _extract(
        apiKey: apiKey,
        slots: slots,
        items: items,
        research: research,
        model: effectiveModel,
      );
    } finally {
      AiCallActivity.finish(activityId);
    }
  }

  // --- Phase 1: grounded research -------------------------------------

  /// Tries [groundingModels] in order, falling through to the next one on
  /// [RateLimitedException] (including "no grounding quota provisioned for
  /// this model", which the API also reports as HTTP 429). Any other failure
  /// propagates immediately, same as [ModelFallbackController]'s rule -
  /// falling through is only for capacity/quota problems, not real errors.
  Future<String> _research({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    required String dietaryNotes,
    required List<String> groundingModels,
  }) async {
    late RateLimitedException lastRateLimitError;
    for (final groundingModel in groundingModels) {
      try {
        return await _researchWithModel(
          apiKey: apiKey,
          slots: slots,
          items: items,
          dietaryNotes: dietaryNotes,
          model: groundingModel,
        );
      } on RateLimitedException catch (e) {
        lastRateLimitError = e;
      }
    }
    // Every model in groundingModels was rate limited (or has no grounding
    // quota at all, which the API also reports as HTTP 429) - nothing left
    // to fall through to.
    throw lastRateLimitError;
  }

  Future<String> _researchWithModel({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    required String dietaryNotes,
    required String model,
  }) async {
    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _researchSystemPrompt},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': _slotsUserText(slots, items, dietaryNotes)},
          ],
        },
      ],
      'tools': [
        {'google_search': <String, dynamic>{}},
      ],
      'generationConfig': {'maxOutputTokens': 8192},
    });

    final decoded = await _post(apiKey: apiKey, model: model, body: body, phase: 'research');
    try {
      final (content, reasonSuffix) = _firstCandidateContent(decoded);
      final parts = content['parts'] as List<dynamic>?;
      if (parts == null) throw Exception('no content in response$reasonSuffix');

      final text = parts
          .whereType<Map<String, dynamic>>()
          .where((p) => p.containsKey('text'))
          .map((p) => p['text'] as String)
          .join('\n');
      if (text.trim().isEmpty) throw Exception('no research text in response$reasonSuffix');

      final usage = decoded['usageMetadata'] as Map<String, dynamic>?;
      await _log(
        model: model,
        phase: 'research',
        success: true,
        inputTokens: (usage?['promptTokenCount'] as num?)?.toInt() ?? 0,
        outputTokens: (usage?['candidatesTokenCount'] as num?)?.toInt() ?? 0,
      );
      return text;
    } catch (e) {
      await _log(model: model, phase: 'research', success: false, errorMessage: stripExceptionPrefix(e));
      rethrow;
    }
  }

  // --- Phase 2: structured extraction ----------------------------------

  Future<MealPlanFull> _extract({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    required String research,
    required String model,
  }) async {
    final userText =
        '${_slotsUserText(slots, items, '')}\n\n'
        'Research notes from the search step - the only source of truth for real recipe URLs. '
        'Never invent or guess a URL that does not appear verbatim below; if a component has no '
        'verified URL in these notes, use type ai_recipe or simple_side instead:\n$research';

    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _extractionSystemPrompt},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': userText},
          ],
        },
      ],
      'tools': [_recordMealComponentsTool],
      'toolConfig': {
        'functionCallingConfig': {
          'mode': 'ANY',
          'allowedFunctionNames': ['record_meal_components'],
        },
      },
      'generationConfig': {'maxOutputTokens': 16384},
    });

    final decoded = await _post(apiKey: apiKey, model: model, body: body, phase: 'extraction');
    try {
      final plan = _parseFull(decoded, slots);
      final usage = decoded['usageMetadata'] as Map<String, dynamic>?;
      await _log(
        model: model,
        phase: 'extraction',
        success: true,
        inputTokens: (usage?['promptTokenCount'] as num?)?.toInt() ?? 0,
        outputTokens: (usage?['candidatesTokenCount'] as num?)?.toInt() ?? 0,
      );
      return plan;
    } catch (e) {
      await _log(
        model: model,
        phase: 'extraction',
        success: false,
        errorMessage: 'Could not parse structured output from the AI response: ${stripExceptionPrefix(e)}',
      );
      rethrow;
    }
  }

  // --- Shared HTTP/error handling ---------------------------------------

  Future<Map<String, dynamic>> _post({
    required String apiKey,
    required String model,
    required String body,
    required String phase,
  }) async {
    final uri = Uri.parse('$_apiBase/$model:generateContent');
    final headers = {'x-goog-api-key': apiKey, 'content-type': 'application/json'};

    final http.Response response;
    try {
      response = await _client.post(uri, headers: headers, body: body);
    } catch (_) {
      await _log(model: model, phase: phase, success: false, errorMessage: 'Could not reach the AI API');
      throw Exception('Could not reach the AI API');
    }

    if (response.statusCode == 429) {
      await _log(model: model, phase: phase, success: false, errorMessage: 'AI API HTTP 429');
      throw RateLimitedException(model);
    }

    if (response.statusCode != 200) {
      await _log(model: model, phase: phase, success: false, errorMessage: 'AI API HTTP ${response.statusCode}');
      throw Exception('AI API HTTP ${response.statusCode}');
    }

    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      await _log(model: model, phase: phase, success: false, errorMessage: 'Invalid JSON from the AI API');
      throw Exception('Invalid JSON from the AI API');
    }
  }

  (Map<String, dynamic>, String) _firstCandidateContent(Map<String, dynamic> decoded) {
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      final blockReason = (decoded['promptFeedback'] as Map<String, dynamic>?)?['blockReason'];
      throw Exception('no candidates returned${blockReason != null ? ' (blockReason: $blockReason)' : ''}');
    }

    final firstCandidate = candidates.first as Map<String, dynamic>;
    final finishReason = firstCandidate['finishReason'] as String?;
    final reasonSuffix = finishReason != null ? ' (finishReason: $finishReason)' : '';

    final content = firstCandidate['content'] as Map<String, dynamic>?;
    if (content == null) throw Exception('no content in response$reasonSuffix');
    return (content, reasonSuffix);
  }

  Future<void> _log({
    required String model,
    required String phase,
    required bool success,
    int inputTokens = 0,
    int outputTokens = 0,
    String? errorMessage,
  }) {
    return _logRepository.add(
      AiCallLog(
        timestamp: DateTime.now(),
        storeName: '$_logStoreName ($phase)',
        model: model,
        success: success,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        errorMessage: errorMessage,
      ),
    );
  }

  // --- Prompt building ----------------------------------------------------

  String _slotsUserText(List<MealSlotPreview> slots, List<DealItem> items, String dietaryNotes) {
    final priority = items.where((i) => i.preference == DealPreference.priority).toList();
    final excluded = items.where((i) => i.preference == DealPreference.excluded).toList();
    final available = items.where((i) => i.preference == DealPreference.neutral).toList();

    final slotsText = slots
        .asMap()
        .entries
        .map((entry) {
          final slot = entry.value;
          final anchors = slot.anchorItems.map((a) => '${a.name} (${a.store})').join(', ');
          return 'Slot ${entry.key + 1}: mealType=${slot.mealType.name}, protein=${slot.protein}, '
              'count=${slot.count} meal-instances, portionsPerMeal=${slot.portionsPerMeal}, '
              'totalPortionsNeeded=${slot.totalPortionsNeeded}, confirmed anchor items: $anchors';
        })
        .join('\n');

    return 'Confirmed meal slots to generate full meals for, in order:\n$slotsText\n\n'
        '${dietaryNotes.trim().isEmpty ? '' : 'Standing planning instructions - follow these across every slot:\n${dietaryNotes.trim()}\n\n'}'
        'Priority deal items (prefer these for carb/vegetable when a good fit exists):\n${_itemsText(priority)}\n\n'
        'Excluded deal items (never use these):\n${_itemsText(excluded)}\n\n'
        'All other available deal items:\n${_itemsText(available)}';
  }

  String _itemsText(List<DealItem> list) {
    if (list.isEmpty) return '(none)';
    return list
        .map(
          (i) =>
              '- ${i.name} (${i.storeName}, ${i.category.label}, ${i.price}${i.unit.isEmpty ? '' : '/${i.unit}'})'
              '${i.isCoverPage ? ' [COVER DEAL]' : ''}',
        )
        .join('\n');
  }

  // --- Response parsing -----------------------------------------------

  MealPlanFull _parseFull(Map<String, dynamic> decoded, List<MealSlotPreview> slots) {
    final (content, reasonSuffix) = _firstCandidateContent(decoded);
    final parts = content['parts'] as List<dynamic>?;
    if (parts == null) throw Exception('no content in response$reasonSuffix');

    Map<String, dynamic>? functionCallPart;
    for (final part in parts) {
      final map = part as Map<String, dynamic>;
      if (map.containsKey('functionCall')) {
        functionCallPart = map;
        break;
      }
    }
    if (functionCallPart == null) throw Exception('no functionCall in response$reasonSuffix');

    final functionCall = functionCallPart['functionCall'] as Map<String, dynamic>;
    final args = functionCall['args'] as Map<String, dynamic>;
    final rawSlots = args['slots'] as List<dynamic>;

    if (rawSlots.length != slots.length) {
      throw Exception('expected ${slots.length} generated slots, got ${rawSlots.length}');
    }

    return MealPlanFull(
      slots: [
        for (var i = 0; i < slots.length; i++)
          MealSlotFull(
            mealType: slots[i].mealType,
            protein: slots[i].protein,
            count: slots[i].count,
            portionsPerMeal: slots[i].portionsPerMeal,
            proteinComponent: _parseComponent((rawSlots[i] as Map<String, dynamic>)['protein'] as Map<String, dynamic>),
            carbComponent: _parseComponent((rawSlots[i] as Map<String, dynamic>)['carb'] as Map<String, dynamic>),
            vegetableComponent: _parseComponent(
              (rawSlots[i] as Map<String, dynamic>)['vegetable'] as Map<String, dynamic>,
            ),
          ),
      ],
    );
  }

  MealComponent _parseComponent(Map<String, dynamic> raw) {
    final rawUrl = (raw['recipeUrl'] as String?)?.trim() ?? '';
    return MealComponent(
      type: MealComponentType.fromValue(raw['type'] as String),
      name: (raw['name'] as String).trim(),
      recipeUrl: rawUrl.isEmpty ? null : rawUrl,
      ingredients: (raw['ingredients'] as List<dynamic>? ?? const [])
          .map((e) => e as Map<String, dynamic>)
          .map((e) => Ingredient(name: (e['name'] as String).trim(), amount: (e['amount'] as String).trim()))
          .toList(),
      instructions: (raw['instructions'] as List<dynamic>? ?? const []).map((e) => (e as String).trim()).toList(),
      note: (raw['note'] as String? ?? '').trim(),
      usesWeeklyDeal: raw['usesWeeklyDeal'] as bool? ?? false,
      dealItems: (raw['dealItems'] as List<dynamic>? ?? const [])
          .map((e) => e as Map<String, dynamic>)
          .map((e) => AnchorItem(name: (e['name'] as String).trim(), store: (e['store'] as String).trim()))
          .toList(),
    );
  }
}

const _researchSystemPrompt = '''
You are researching the recipes needed to turn confirmed meal-plan slots into full batch-cooked meals. Each slot is ONE recipe, batch-cooked once, that must yield its totalPortionsNeeded - not one recipe per meal instance.

Every meal (slot) is composed of exactly 3 components: protein, carb, vegetable.

For the protein: it is built from the slot's confirmed anchor item(s), scaled to totalPortionsNeeded. Use your search tool to find and verify a real recipe URL for it. PREFER a real, verified recipe link over an AI-authored recipe - only fall back to describing an AI-authored recipe if no suitable real recipe can be found and verified. Never report a URL you have not actually looked up and confirmed exists.

MULTI-COMPONENT CHECK: once you have a candidate protein recipe, check whether it already explicitly includes a carb and/or a vegetable as an actual ingredient - meaning the item appears in the ingredient list and is prepared/cooked as part of the recipe steps, not just mentioned in a closing "serve with X" suggestion. Report clearly, per component, whether it is covered this way.

For any component NOT already covered by the protein recipe:
- carb: pick a complementary carb. It does not need to come from this week's deals - pantry staples (rice, couscous, quinoa, pasta, etc.) are always fine. Use a deal item only if a good fit exists this week. PREFER a verified real recipe link over an AI-authored recipe; a short "simple side" prep note (no full recipe) is also a valid and often better choice for a plain carb.
- vegetable: same logic - prefer a deal item if a good fit exists this week, otherwise any vegetable. PREFER a verified real recipe link; a simple side prep note is also valid.

For every link you propose (protein, carb, or vegetable), you must have actually used your search tool to find and confirm it is a real, working recipe URL. If you cannot verify a link for a component, say so explicitly and instead sketch a short AI-authored recipe or a simple-side note for it.

Excluded deal items must never be used in any component.

Write your findings as clear, per-slot notes covering: the protein recipe name and verified URL (or "no verified link found" plus an AI-recipe sketch), whether the carb/vegetable are covered by that recipe, and for each uncovered component its proposed name, verified URL (if any) or AI-recipe sketch or simple-side note, and whether it uses a deal item (naming the item and store).
''';

const _extractionSystemPrompt = '''
You are converting research notes into a structured meal plan. You are given confirmed meal slots, the week's deal items, and research notes from a prior search step describing candidate protein/carb/vegetable components for each slot, including any verified recipe URLs that were found.

Every meal (slot) is composed of exactly 3 components: protein, carb, vegetable. For each slot, in the same order given, record:

- protein: scaled to totalPortionsNeeded, built from the slot's confirmed anchor item(s).
- carb and vegetable: each either covered_by_protein (when the research notes say the protein recipe already explicitly includes it - reference the same recipeUrl as the protein component in that case), or its own component.

For every component, choose exactly one type: "link" (a real URL - only ever one that appears verbatim in the research notes below, never invented), "ai_recipe" (full ingredients + instructions, used only when the research notes found no verified link), "simple_side" (a short prep note, no full recipe - valid for carb/vegetable, not for protein), or "covered_by_protein" (carb/vegetable only).

Do not invent, guess, or reconstruct a URL that is not present verbatim in the research notes - if the notes report no verified link for a component, use ai_recipe or simple_side instead.

Set usesWeeklyDeal and dealItems (name + store, from the deal items given) truthfully for each component, based on whether it draws on one of this week's deal items - most protein components will, carb/vegetable only when the research notes say so.

Leave recipeUrl as an empty string when the component has no URL (ai_recipe, simple_side). Leave ingredients/instructions empty for simple_side and covered_by_protein. Leave note empty except for simple_side, where it holds the short prep note.

Record exactly one entry per meal slot, in the same order the slots were given, by calling record_meal_components.
''';

const _mealComponentSchema = {
  'type': 'OBJECT',
  'properties': {
    'type': {
      'type': 'STRING',
      'enum': ['link', 'ai_recipe', 'simple_side', 'covered_by_protein'],
    },
    'name': {'type': 'STRING'},
    'recipeUrl': {'type': 'STRING'},
    'ingredients': {
      'type': 'ARRAY',
      'items': {
        'type': 'OBJECT',
        'properties': {
          'name': {'type': 'STRING'},
          'amount': {'type': 'STRING'},
        },
        'required': ['name', 'amount'],
      },
    },
    'instructions': {
      'type': 'ARRAY',
      'items': {'type': 'STRING'},
    },
    'note': {'type': 'STRING'},
    'usesWeeklyDeal': {'type': 'BOOLEAN'},
    'dealItems': {
      'type': 'ARRAY',
      'items': {
        'type': 'OBJECT',
        'properties': {
          'name': {'type': 'STRING'},
          'store': {'type': 'STRING'},
        },
        'required': ['name', 'store'],
      },
    },
  },
  'required': ['type', 'name', 'recipeUrl', 'ingredients', 'instructions', 'note', 'usesWeeklyDeal', 'dealItems'],
};

const _recordMealComponentsTool = {
  'functionDeclarations': [
    {
      'name': 'record_meal_components',
      'description': 'Records the protein/carb/vegetable components for every meal slot, in the order given.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'slots': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'protein': _mealComponentSchema,
                'carb': _mealComponentSchema,
                'vegetable': _mealComponentSchema,
              },
              'required': ['protein', 'carb', 'vegetable'],
            },
          },
        },
        'required': ['slots'],
      },
    },
  ],
};
