import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_call_log.dart';
import '../models/deal_item.dart';
import '../models/meal_history.dart';
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
  ///
  /// [alreadyUsedAnchors] lists anchor items already committed to OTHER
  /// slots of the same plan that aren't part of this call - e.g. every
  /// other slot's anchors when regenerating a single slot. The AI is told
  /// not to reuse them, since an ingredient shouldn't anchor more than one
  /// slot even when it's a priority item. When every slot is generated in
  /// one call, cross-slot uniqueness is instead enforced by the prompt
  /// alone, since the AI sees every slot at once.
  ///
  /// [otherSlots] are the plan's OTHER slots (with their counts and
  /// proteins) when only some slots are being (re)generated - unlike
  /// [alreadyUsedAnchors], which only names their items, this lets the AI
  /// enforce plan-wide frequency limits from the standing instructions
  /// (e.g. "no more than 2 days of fish") across slots it isn't choosing.
  ///
  /// [recentlyUsed] lists recipes/deal items from saved plan history within
  /// the configured diversity window - a soft "try to vary" hint, unlike
  /// [alreadyUsedAnchors] which is a hard same-plan exclusion.
  Future<MealPlanPreview> previewMealPlan({
    required String apiKey,
    required List<MealSlot> mealSlots,
    required int portionsPerMeal,
    required List<DealItem> items,
    List<AnchorItem> alreadyUsedAnchors = const [],
    List<MealSlotPreview> otherSlots = const [],
    List<RecentHistoryItem> recentlyUsed = const [],
    String dietaryNotes = '',
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
        alreadyUsedAnchors: alreadyUsedAnchors,
        otherSlots: otherSlots,
        recentlyUsed: recentlyUsed,
        dietaryNotes: dietaryNotes,
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
    required List<AnchorItem> alreadyUsedAnchors,
    required List<MealSlotPreview> otherSlots,
    required List<RecentHistoryItem> recentlyUsed,
    required String dietaryNotes,
    required String model,
  }) async {
    final uri = Uri.parse('$_apiBase/$model:generateContent');
    final headers = {'x-goog-api-key': apiKey, 'content-type': 'application/json'};
    final body = jsonEncode(
      _buildRequestBody(mealSlots, portionsPerMeal, items, alreadyUsedAnchors, otherSlots, recentlyUsed, dietaryNotes),
    );

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
      await _log(
        model: model,
        success: true,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        details: _instructionCheck(decoded),
      );
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
    String? details,
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
        details: details,
      ),
    );
  }

  /// The model's own instructionCheck reasoning, kept in the AI call log so
  /// a plan that breaks a standing instruction can be traced back to how
  /// the model (mis)read it. Null when absent - it's diagnostic only.
  String? _instructionCheck(Map<String, dynamic> decoded) {
    final parts = ((decoded['candidates'] as List<dynamic>?)?.firstOrNull as Map<String, dynamic>?)?['content']?['parts'];
    if (parts is! List) return null;
    for (final part in parts) {
      final args = (part as Map<String, dynamic>)['functionCall']?['args'];
      if (args is Map<String, dynamic>) {
        final check = (args['instructionCheck'] as String?)?.trim();
        return check == null || check.isEmpty ? null : 'Instruction check: $check';
      }
    }
    return null;
  }

  Map<String, dynamic> _buildRequestBody(
    List<MealSlot> mealSlots,
    int portionsPerMeal,
    List<DealItem> items,
    List<AnchorItem> alreadyUsedAnchors,
    List<MealSlotPreview> otherSlots,
    List<RecentHistoryItem> recentlyUsed,
    String dietaryNotes,
  ) {
    final priority = items.where((i) => i.preference == DealPreference.priority).toList();
    final excluded = items.where((i) => i.preference == DealPreference.excluded).toList();
    final available = items.where((i) => i.preference == DealPreference.neutral).toList();

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
        '${otherSlots.isEmpty ? '' : 'Other slots already in this plan, not part of this call - their anchors are fixed, '
              'but count their days toward any frequency limit in the standing instructions:\n${_otherSlotsText(otherSlots)}\n\n'}'
        '${dietaryNotes.trim().isEmpty ? '' : 'Standing planning instructions - follow these across every slot:\n${dietaryNotes.trim()}\n\n'}'
        'Priority deal items (prefer these first):\n${_itemsText(priority)}\n\n'
        'Excluded deal items (never propose these):\n${_itemsText(excluded)}\n\n'
        'All other available deal items:\n${_itemsText(available)}\n\n'
        'Deal items already used as anchors elsewhere in this plan - never propose any of these '
        'for the slot(s) below, even if they are priority items:\n${_anchorItemsText(alreadyUsedAnchors)}\n\n'
        'Recently used (within the last diversity-window days, from saved history) - try to vary '
        'away from these rather than repeating them, but a repeat is fine if it is clearly the best '
        'fit for this week\'s deals (e.g. an exceptional price on the same protein). This is guidance, '
        'not an exclusion:\n${_recentHistoryText(recentlyUsed)}';

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
      // Room for the instructionCheck reasoning written before the slots, so
      // a long check can't crowd the slots themselves out of the response.
      'generationConfig': {'maxOutputTokens': 16384},
    };
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

  String _otherSlotsText(List<MealSlotPreview> list) {
    return list
        .map(
          (s) =>
              '- ${s.mealType.name}, protein=${s.protein}, count=${s.count} days, anchors: '
              '${s.anchorItems.isEmpty ? '(none)' : _anchorItemsInlineText(s.anchorItems)}',
        )
        .join('\n');
  }

  String _anchorItemsText(List<AnchorItem> list) {
    if (list.isEmpty) return '(none)';
    return list.map((a) => '- ${a.name} (${a.store})').join('\n');
  }

  String _recentHistoryText(List<RecentHistoryItem> list) {
    if (list.isEmpty) return '(none)';
    return list
        .map((r) => '- "${r.recipeName}" using ${_anchorItemsInlineText(r.dealItemsUsed)}')
        .join('\n');
  }

  String _anchorItemsInlineText(List<AnchorItem> list) {
    if (list.isEmpty) return '(no tracked deal items)';
    return list.map((a) => '${a.name} (${a.store})').join(', ');
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
            final name = (map['name'] as String).trim();
            final store = (map['store'] as String? ?? '').trim();
            final isPantry =
                map['pantry'] == true || store.isEmpty || store.toLowerCase() == AnchorItem.pantryStore.toLowerCase();
            return isPantry
                ? AnchorItem.pantry(name)
                : AnchorItem(name: name, store: store, role: AnchorRole.fromName(map['role'] as String?));
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

For each meal slot, propose the anchor item(s) that define this slot's big-batch recipe: always the main protein item, always exactly one carb (see CARB below), plus a vegetable side when one naturally fits that direction or when a priority vegetable is available and fits - don't force a vegetable pick just to fill a slot when nothing fits well.

CARB: every slot must have exactly one carb anchor - never leave a slot without one. Use a carb deal item (category Carbs) when one fits the slot's direction (e.g. a pasta deal for a pasta bake); otherwise pick a pantry staple that suits the dish - e.g. rice (basmati, jasmine), quinoa, couscous, pasta, egg noodles, rice noodles, potatoes, sweet potatoes, bulgur, orzo, barley, tortillas, naan or bread. Give every anchor its role in the meal: "protein", "carb" (exactly one per slot), "vegetable", or "other" for anything else. Decide the role from what the item actually is, not from the category its deal is listed under - a protein such as tofu, meat or fish is never the carb. Record a pantry staple with pantry=true and store "Pantry"; record a carb deal item with pantry=false and its real store. Vary the carb across the slots of the plan (and against the other slots listed below) - don't give two slots the same carb unless there is no sensible alternative. Never record a pantry item for anything but the carb: proteins and vegetables always come from the deal items. Prioritize items marked as priority over other available deal items whenever one reasonably fits the slot, across every category (protein, vegetables, carbs) - always try to work a priority item into the anchor set when possible, not just for the protein. Items marked [COVER DEAL] are the flyer's featured best deals - prefer one when it reasonably fits a slot, especially for the vegetable/carb side. Draw from priority items first, then the other available deal items. Never propose an excluded item. Size the selection conceptually for a big-batch recipe covering the slot's total portions needed - do not invent a recipe name or instructions yet.

No ingredient may anchor more than one slot in this plan, even a priority item that would otherwise fit several slots well - each slot's anchors must be entirely distinct from every other slot's. This means the same product, not just the same exact listing: don't anchor one slot on broccoli from one store and another slot on broccoli from a different store (or a differently-worded listing of the same thing) - that still counts as reusing the same ingredient. When multiple slots are given in the same call, check your own choices for cross-slot duplicates (by ingredient, not just by exact name/store) as you go. A list of deal items already used as anchors elsewhere in this plan may also be given below - never reuse any of those either, by the same ingredient-level rule, and pick a different item for any slot that would otherwise repeat one.

Standing planning instructions may be given below the meal slots - these are hard constraints from the user that apply across every slot in this plan, and take priority over item preference (priority/cover-deal) when the two conflict. Follow them exactly as written. Read them carefully:
- They apply across languages and to every variety of what they name. Deal items are often listed in French while the instructions may be in English (or the reverse): "no squash" rules out "courge musquée", "courge spaghetti", "courge butternut" and other winter squash; "no fish" rules out "filet de truite", "saumon", "tilapia", "morue", etc. Translate each deal item's name before checking it against an instruction. Apply an instruction to what it clearly names in everyday cooking terms - don't stretch it to loosely related items the user didn't mean (e.g. "no squash" alone doesn't rule out zucchini/courgette).
- A slot's count is the number of days that recipe is eaten - one batch-cooked recipe covers every meal instance in the slot. So a frequency limit such as "no more than 2 days of fish" means fish may only anchor slots whose counts add up to at most 2 across the whole plan - including any "other slots already in this plan" listed below, which already use up part of the limit: never anchor a count=5 (or count=3) slot on fish under that instruction, even when the slot's protein is a generic word like "meat" and fish is the best deal. Pick a different protein item for that slot instead.
- They apply to every anchor item, not just the protein - a vegetable or carb anchor must follow them too.

Before choosing any anchors, fill in instructionCheck: one short line per standing instruction saying how your picks respect it (for a frequency limit, add up the counts of the slots it applies to, other slots included). Keep it brief - a few lines, not an essay. Then make sure the anchors you record match what you wrote there.

A list of recently used recipes and their deal items, drawn from saved plan history within the configured diversity window, may also be given below - this is a soft preference, not a rule: prefer a different recipe or anchor over repeating one of these, but a repeat is still fine when it's clearly the best fit for this week's deals (e.g. an exceptional price on the same protein). Never let this override a standing planning instruction or an excluded item.

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
          // Filled in first (see propertyOrdering) so the model works
          // through each standing instruction against every slot before
          // committing to anchors - free-form instructions were otherwise
          // easy for it to skim past. Not parsed; it exists only to make
          // the model reason before choosing.
          'instructionCheck': {
            'type': 'STRING',
            'description':
                'For each standing planning instruction, how every slot\'s picks respect it (including slot counts for '
                'frequency limits and translated item names). "(no standing instructions)" if there are none.',
          },
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
                      // True only for the slot's pantry-staple carb (not a
                      // deal item) - see the CARB rule in the system prompt.
                      'pantry': {'type': 'BOOLEAN'},
                      // Which part of the meal this anchor is.
                      'role': {
                        'type': 'STRING',
                        'enum': ['protein', 'carb', 'vegetable', 'other'],
                      },
                    },
                    'required': ['name', 'store', 'pantry', 'role'],
                  },
                },
                'note': {'type': 'STRING'},
              },
              'required': ['anchorItems', 'note'],
            },
          },
        },
        'required': ['instructionCheck', 'slots'],
        'propertyOrdering': ['instructionCheck', 'slots'],
      },
    },
  ],
};
