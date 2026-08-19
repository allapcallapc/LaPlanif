import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_call_log.dart';
import '../models/deal_item.dart';
import '../models/meal_plan_config.dart';
import '../models/meal_plan_preview.dart';
import '../utils/error_formatting.dart';
import 'ai_call_activity.dart';
import 'ai_call_log_repository.dart';
import 'ai_config_repository.dart';
import 'model_fallback_controller.dart';

/// Proposes one anchor-item set per [MealSlot] - the main protein plus 1-2
/// key supporting items for that slot's batch-cooked recipe - using the
/// Google AI (Gemini) API. This is a non-binding checkpoint before full
/// recipe generation: no recipe name or instructions are produced here.
class MealPlanPreviewService {
  MealPlanPreviewService({http.Client? client, String? model, AiCallLogRepository? logRepository})
    : model = model ?? AiConfigRepository.defaultModels.first,
      _client = client ?? http.Client(),
      _logRepository = logRepository ?? AiCallLogRepository();

  static const _apiBase = 'https://generativelanguage.googleapis.com/v1beta/models';

  /// Stand-in "store name" for logging/in-flight-activity purposes - this
  /// call isn't tied to a particular store, unlike deal extraction.
  static const _logStoreName = 'Meal plan preview';

  final http.Client _client;
  final AiCallLogRepository _logRepository;
  final String model;

  /// Proposes anchor items for every slot in [mealSlots], in one call. Deal
  /// items with [DealPreference.excluded] are told apart from the rest so
  /// the AI never proposes them; the rest (priority first) are offered as
  /// candidates.
  Future<MealPlanPreview> previewMealPlan({
    required String apiKey,
    required List<MealSlot> mealSlots,
    required int portionsPerMeal,
    required List<DealItem> items,
    String? model,
  }) async {
    final effectiveModel = model ?? this.model;
    final activityId = AiCallActivity.start(storeName: _logStoreName, model: effectiveModel);
    try {
      return await _previewTracked(
        apiKey: apiKey,
        mealSlots: mealSlots,
        portionsPerMeal: portionsPerMeal,
        items: items,
        model: effectiveModel,
      );
    } finally {
      AiCallActivity.finish(activityId);
    }
  }

  Future<MealPlanPreview> _previewTracked({
    required String apiKey,
    required List<MealSlot> mealSlots,
    required int portionsPerMeal,
    required List<DealItem> items,
    required String model,
  }) async {
    final uri = Uri.parse('$_apiBase/$model:generateContent');
    final headers = {'x-goog-api-key': apiKey, 'content-type': 'application/json'};
    final body = jsonEncode(_buildRequestBody(mealSlots, portionsPerMeal, items));

    final http.Response response;
    try {
      response = await _client.post(uri, headers: headers, body: body);
    } catch (_) {
      await _log(model: model, success: false, errorMessage: 'Could not reach the AI API');
      throw Exception('Could not reach the AI API');
    }

    if (response.statusCode == 429) {
      await _log(model: model, success: false, errorMessage: 'AI API HTTP 429');
      throw RateLimitedException(model);
    }

    if (response.statusCode != 200) {
      await _log(model: model, success: false, errorMessage: 'AI API HTTP ${response.statusCode}');
      throw Exception('AI API HTTP ${response.statusCode}');
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      await _log(model: model, success: false, errorMessage: 'Invalid JSON from the AI API');
      throw Exception('Invalid JSON from the AI API');
    }

    final usage = decoded['usageMetadata'] as Map<String, dynamic>?;
    final inputTokens = (usage?['promptTokenCount'] as num?)?.toInt() ?? 0;
    final outputTokens = (usage?['candidatesTokenCount'] as num?)?.toInt() ?? 0;

    try {
      final preview = _parsePreview(decoded, mealSlots, portionsPerMeal);
      await _log(model: model, success: true, inputTokens: inputTokens, outputTokens: outputTokens);
      return preview;
    } catch (e) {
      await _log(
        model: model,
        success: false,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        errorMessage: 'Could not parse structured output from the AI response: ${stripExceptionPrefix(e)}',
      );
      rethrow;
    }
  }

  Future<void> _log({
    required String model,
    required bool success,
    int inputTokens = 0,
    int outputTokens = 0,
    String? errorMessage,
  }) {
    return _logRepository.add(
      AiCallLog(
        timestamp: DateTime.now(),
        storeName: _logStoreName,
        model: model,
        success: success,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        errorMessage: errorMessage,
      ),
    );
  }

  Map<String, dynamic> _buildRequestBody(List<MealSlot> mealSlots, int portionsPerMeal, List<DealItem> items) {
    final priority = items.where((i) => i.preference == DealPreference.priority).toList();
    final excluded = items.where((i) => i.preference == DealPreference.excluded).toList();
    final available = items.where((i) => i.preference != DealPreference.excluded).toList();

    final slotsText = mealSlots
        .asMap()
        .entries
        .map((entry) {
          final slot = entry.value;
          final total = slot.count * portionsPerMeal;
          return 'Slot ${entry.key + 1}: mealType=${slot.mealType.name}, protein=${slot.protein}, '
              'count=${slot.count} meal-instances, portionsPerMeal=$portionsPerMeal, totalPortionsNeeded=$total';
        })
        .join('\n');

    final userText =
        'Meal slots to propose anchors for, in order:\n$slotsText\n\n'
        'Priority deal items (prefer these first):\n${_itemsText(priority)}\n\n'
        'Excluded deal items (never propose these):\n${_itemsText(excluded)}\n\n'
        'All other available deal items:\n${_itemsText(available)}';

    return {
      'systemInstruction': {
        'parts': [
          {'text': _systemPrompt},
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
      'tools': [_recordSlotPreviewsTool],
      'toolConfig': {
        'functionCallingConfig': {
          'mode': 'ANY',
          'allowedFunctionNames': ['record_slot_previews'],
        },
      },
      'generationConfig': {'maxOutputTokens': 8192},
    };
  }

  String _itemsText(List<DealItem> list) {
    if (list.isEmpty) return '(none)';
    return list
        .map((i) => '- ${i.name} (${i.storeName}, ${i.category.label}, ${i.price}${i.unit.isEmpty ? '' : '/${i.unit}'})')
        .join('\n');
  }

  MealPlanPreview _parsePreview(Map<String, dynamic> decoded, List<MealSlot> mealSlots, int portionsPerMeal) {
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      final blockReason = (decoded['promptFeedback'] as Map<String, dynamic>?)?['blockReason'];
      throw Exception('no candidates returned${blockReason != null ? ' (blockReason: $blockReason)' : ''}');
    }

    final firstCandidate = candidates.first as Map<String, dynamic>;
    final finishReason = firstCandidate['finishReason'] as String?;
    final reasonSuffix = finishReason != null ? ' (finishReason: $finishReason)' : '';

    final content = firstCandidate['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null) {
      throw Exception('no content in response$reasonSuffix');
    }

    Map<String, dynamic>? functionCallPart;
    for (final part in parts) {
      final map = part as Map<String, dynamic>;
      if (map.containsKey('functionCall')) {
        functionCallPart = map;
        break;
      }
    }
    if (functionCallPart == null) {
      throw Exception('no functionCall in response$reasonSuffix');
    }

    final functionCall = functionCallPart['functionCall'] as Map<String, dynamic>;
    final args = functionCall['args'] as Map<String, dynamic>;
    final rawSlots = args['slots'] as List<dynamic>;

    if (rawSlots.length != mealSlots.length) {
      throw Exception('expected ${mealSlots.length} slot previews, got ${rawSlots.length}');
    }

    final slots = <MealSlotPreview>[];
    for (var i = 0; i < mealSlots.length; i++) {
      final slot = mealSlots[i];
      final raw = rawSlots[i] as Map<String, dynamic>;
      final rawAnchors = raw['anchorItems'] as List<dynamic>;
      slots.add(
        MealSlotPreview(
          mealType: slot.mealType,
          protein: slot.protein,
          count: slot.count,
          portionsPerMeal: portionsPerMeal,
          anchorItems: rawAnchors.map((a) {
            final map = a as Map<String, dynamic>;
            return AnchorItem(name: (map['name'] as String).trim(), store: (map['store'] as String).trim());
          }).toList(),
          note: (raw['note'] as String).trim(),
        ),
      );
    }
    return MealPlanPreview(slots: slots);
  }
}

const _systemPrompt = '''
You are planning a non-binding meal-plan preview: a checkpoint before full recipe generation.

Each meal slot represents ONE recipe, batch-cooked once, that must yield enough portions to cover every meal instance in that slot - not one recipe per instance. A slot with count=5 and portionsPerMeal=3 needs one recipe that yields 15 portions total, batch-cooked once and portioned out across the week.

For each meal slot, propose the anchor item(s) that define this slot's big-batch recipe: always the main protein item, plus a vegetable or carb side when one naturally fits that direction (e.g. rice alongside a stir-fry, potatoes alongside a roast) or when a priority item in that category is available and fits - don't force a vegetable/carb pick just to fill a slot when nothing fits well. Prioritize items marked as priority over other available deal items whenever one reasonably fits the slot, across every category (protein, vegetables, carbs) - always try to work a priority item into the anchor set when possible, not just for the protein. Draw from priority items first, then the other available deal items. Never propose an excluded item. Size the selection conceptually for a big-batch recipe covering the slot's total portions needed - do not invent a recipe name or instructions yet.

Also write a one-line note describing the direction for that slot's recipe (e.g. "Big-batch chicken thigh stir-fry with rice, portioned across the week.").

Propose exactly one entry per meal slot, in the same order the slots were given, and record it by calling record_slot_previews.
''';

const _recordSlotPreviewsTool = {
  'functionDeclarations': [
    {
      'name': 'record_slot_previews',
      'description': 'Records one anchor-item proposal per meal slot, in the same order the slots were given.',
      'parameters': {
        'type': 'OBJECT',
        'properties': {
          'slots': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'anchorItems': {
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
                'note': {'type': 'STRING'},
              },
              'required': ['anchorItems', 'note'],
            },
          },
        },
        'required': ['slots'],
      },
    },
  ],
};
