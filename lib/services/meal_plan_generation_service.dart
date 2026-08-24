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
///    the caller's chosen [model] - grounding support and free-tier
///    availability can vary by account (e.g. a model can be paid-tier-only,
///    unrelated to grounding itself), so the research step has its own,
///    separately configurable model list in Config, in case a given
///    account's working model differs from the one used elsewhere.
/// 2. A structured extraction call (function calling) that converts those
///    research notes into the typed component format, without doing any
///    search itself. It never writes out a recipe URL as text - the research
///    call's search tool results (`groundingMetadata.groundingChunks`) are
///    the only real URLs, and they're long opaque redirect links a model
///    reliably mangles if asked to retype them, so instead the extraction
///    call picks a numeric `sourceIndex` into that list, which
///    [_parseComponent] resolves to the real URL (or, for an out-of-range
///    index, downgrades to an AI-authored recipe rather than a dead link).
///    This call has no grounding requirement, so it uses the caller's chosen
///    [model] like any other call in the app.
///
/// Each grounding source's URL is itself an opaque
/// `vertexaisearch.cloud.google.com/grounding-api-redirect/...` link, not
/// the real recipe page - [_resolveRecipeLink] gets one chance to resolve it
/// to the real destination (see `redirect_resolver.dart`) right after the
/// research call, before it's shown to the extraction step or the user; on
/// any failure (most likely: the redirect target doesn't allow a
/// cross-origin read) the original redirect link is kept as-is, since it
/// still works as a plain link even though it can't be read as text.
class MealPlanGenerationService {
  MealPlanGenerationService({
    http.Client? client,
    String? model,
    List<String>? groundingModels,
    AiCallLogRepository? logRepository,
    Future<String?> Function(String url)? resolveRecipeLink,
  }) : model = model ?? AiConfigRepository.defaultModels.first,
       groundingModels = groundingModels ?? AiConfigRepository.defaultGroundingModels,
       _client = client ?? http.Client(),
       _logRepository = logRepository ?? AiCallLogRepository(),
       // Defaults to a no-op (keep the original redirect link) rather than
       // the real fetch-based resolver - the real one is wired in
       // explicitly at this app's one production call site
       // (PlanifScreen's default generationService), so tests that
       // construct this service directly never touch a real network/browser
       // API. See redirect_resolver.dart for why resolution can fail.
       _resolveRecipeLink = resolveRecipeLink ?? ((_) async => null),
       assert(
         (groundingModels ?? AiConfigRepository.defaultGroundingModels).isNotEmpty,
         'groundingModels must not be empty',
       );

  static const _apiBase = 'https://generativelanguage.googleapis.com/v1beta/models';
  static const _logStoreName = 'Meal plan generation';

  final http.Client _client;
  final AiCallLogRepository _logRepository;
  final Future<String?> Function(String url) _resolveRecipeLink;
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
      final (research, sources) = await _research(
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
        sources: sources,
        model: effectiveModel,
      );
    } finally {
      AiCallActivity.finish(activityId);
    }
  }

  // --- Phase 1: grounded research -------------------------------------

  /// Tries [groundingModels] in order, falling through to the next one on
  /// [RateLimitedException] (HTTP 429 - rate limited or out of quota). Any
  /// other failure propagates immediately, same as [ModelFallbackController]'s
  /// rule - falling through is only for capacity/quota problems, not real
  /// errors (e.g. a paid-only model returns HTTP 404 on a free-tier key,
  /// which isn't retried here).
  Future<(String, List<_GroundingSource>)> _research({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    required String dietaryNotes,
    required List<String> groundingModels,
  }) async {
    RateLimitedException? lastRateLimitError;
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
    if (lastRateLimitError == null) {
      throw ArgumentError.value(groundingModels, 'groundingModels', 'must not be empty');
    }
    // Every model in groundingModels was rate limited (or has no grounding
    // quota at all, which the API also reports as HTTP 429) - nothing left
    // to fall through to.
    throw lastRateLimitError;
  }

  Future<(String, List<_GroundingSource>)> _researchWithModel({
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
      'generationConfig': {'maxOutputTokens': 16384},
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
      return (text, await _resolveSources(_groundingSources(decoded)));
    } catch (e) {
      await _log(model: model, phase: 'research', success: false, errorMessage: stripExceptionPrefix(e));
      rethrow;
    }
  }

  /// Pulls the actual search-grounding sources the API attached to the
  /// research response (`groundingMetadata.groundingChunks[].web`) - the only
  /// URLs Google's own grounding vouches for as real search hits. The
  /// research call's free-text notes are written by the model and can
  /// describe a URL it reconstructed from memory (e.g. a plausible-looking
  /// `/recipe/244795/...` pattern) rather than one it actually found, so
  /// those notes alone aren't a reliable source of truth for a working link -
  /// only this list is, and [_parseComponent] enforces that downstream.
  List<_GroundingSource> _groundingSources(Map<String, dynamic> decoded) {
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) return const [];
    final groundingMetadata = (candidates.first as Map<String, dynamic>)['groundingMetadata'] as Map<String, dynamic>?;
    final chunks = groundingMetadata?['groundingChunks'] as List<dynamic>? ?? const [];

    final sources = <_GroundingSource>[];
    final seenUris = <String>{};
    for (final chunk in chunks) {
      final web = (chunk as Map<String, dynamic>?)?['web'] as Map<String, dynamic>?;
      final uri = (web?['uri'] as String?)?.trim();
      if (uri == null || uri.isEmpty || !seenUris.add(uri)) continue;
      sources.add(_GroundingSource(uri: uri, title: (web?['title'] as String? ?? '').trim()));
    }
    return sources;
  }

  /// Gives [_resolveRecipeLink] one chance per source to swap its opaque
  /// redirect [_GroundingSource.uri] for the real destination URL, in
  /// parallel. A resolver failure (null, or any thrown exception - a
  /// custom-injected resolver isn't trusted to always catch its own) keeps
  /// that source's original redirect link rather than dropping it.
  Future<List<_GroundingSource>> _resolveSources(List<_GroundingSource> sources) {
    return Future.wait(
      sources.map((source) async {
        String? resolvedUrl;
        try {
          resolvedUrl = await _resolveRecipeLink(source.uri);
        } catch (_) {
          resolvedUrl = null;
        }
        return resolvedUrl == null ? source : _GroundingSource(uri: resolvedUrl, title: source.title);
      }),
    );
  }

  // --- Phase 2: structured extraction ----------------------------------

  Future<MealPlanFull> _extract({
    required String apiKey,
    required List<MealSlotPreview> slots,
    required List<DealItem> items,
    required String research,
    required List<_GroundingSource> sources,
    required String model,
  }) async {
    final userText =
        '${_slotsUserText(slots, items, '')}\n\n'
        'Research notes from the search step, for context on which recipe fits which slot:\n$research\n\n'
        'Verified search sources, numbered - the ONLY sources you may ever cite for type "link". These are '
        'the actual links Google Search returned, not the research notes\' prose. To use one, match it to '
        'the recipe it describes (by title) and set that component\'s sourceIndex to its number below - do '
        'NOT type out the URL yourself, even if you recognize it or are confident you know it; these URLs '
        'are long opaque redirect links that must be selected by index, never retyped from memory or '
        'reconstructed, since even one changed or dropped character produces a dead link. Set sourceIndex '
        'to -1 for every component that is not type "link". If a component has no matching entry here, use '
        'type ai_recipe or simple_side instead:\n${_sourcesText(sources)}';

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
      final plan = _parseFull(decoded, slots, sources);
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

  String _sourcesText(List<_GroundingSource> sources) {
    if (sources.isEmpty) return '(none - no search sources were returned; do not use type "link" for any component)';
    return sources
        .asMap()
        .entries
        .map((e) => '[${e.key}] ${e.value.uri}${e.value.title.isEmpty ? '' : ' (${e.value.title})'}')
        .join('\n');
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

  MealPlanFull _parseFull(Map<String, dynamic> decoded, List<MealSlotPreview> slots, List<_GroundingSource> sources) {
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
        for (var i = 0; i < slots.length; i++) _parseSlot(slots[i], rawSlots[i] as Map<String, dynamic>, sources),
      ],
    );
  }

  MealSlotFull _parseSlot(MealSlotPreview slot, Map<String, dynamic> rawSlot, List<_GroundingSource> sources) {
    final protein = _parseComponent(rawSlot['protein'] as Map<String, dynamic>, sources);
    var carb = _parseComponent(rawSlot['carb'] as Map<String, dynamic>, sources);
    var vegetable = _parseComponent(rawSlot['vegetable'] as Map<String, dynamic>, sources);
    // covered_by_protein always points at the same recipe as the protein
    // component - resolve it from the protein's own (already-verified)
    // recipeUrl rather than trusting a second independent sourceIndex.
    if (carb.type == MealComponentType.coveredByProtein) {
      carb = _withRecipeLink(carb, protein.recipeUrl, protein.recipeSourceTitle);
    }
    if (vegetable.type == MealComponentType.coveredByProtein) {
      vegetable = _withRecipeLink(vegetable, protein.recipeUrl, protein.recipeSourceTitle);
    }
    return MealSlotFull(
      mealType: slot.mealType,
      protein: slot.protein,
      count: slot.count,
      portionsPerMeal: slot.portionsPerMeal,
      proteinComponent: protein,
      carbComponent: carb,
      vegetableComponent: vegetable,
    );
  }

  MealComponent _withRecipeLink(MealComponent component, String? recipeUrl, String? recipeSourceTitle) => MealComponent(
    type: component.type,
    name: component.name,
    recipeUrl: recipeUrl,
    recipeSourceTitle: recipeSourceTitle,
    ingredients: component.ingredients,
    instructions: component.instructions,
    note: component.note,
    usesWeeklyDeal: component.usesWeeklyDeal,
    dealItems: component.dealItems,
  );

  MealComponent _parseComponent(Map<String, dynamic> raw, List<_GroundingSource> sources) {
    var type = MealComponentType.fromValue(raw['type'] as String);
    String? recipeUrl;
    String? recipeSourceTitle;
    if (type == MealComponentType.link) {
      // The model never writes out the URL itself - it only picks a
      // sourceIndex into the verified search-grounding source list (see
      // _extract), since these URLs are long opaque redirect links models
      // reliably mangle when asked to retype them. An out-of-range index
      // means it didn't actually have a real source to point at, so there's
      // no link to give the user - fall back to an AI-authored recipe
      // rather than a hallucinated or dead one.
      final sourceIndex = (raw['sourceIndex'] as num?)?.toInt() ?? -1;
      if (sourceIndex >= 0 && sourceIndex < sources.length) {
        recipeUrl = sources[sourceIndex].uri;
        final title = sources[sourceIndex].title;
        recipeSourceTitle = title.isEmpty ? null : title;
      } else {
        type = MealComponentType.aiRecipe;
      }
    }
    return MealComponent(
      type: type,
      name: (raw['name'] as String).trim(),
      recipeUrl: recipeUrl,
      recipeSourceTitle: recipeSourceTitle,
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

For the protein: it is built from the slot's confirmed anchor item(s), scaled to totalPortionsNeeded. Use your search tool to find and verify a real recipe URL for it. A real, verified recipe link is REQUIRED unless none can be found - this is a hard requirement, not a soft preference. Falling back to an AI-authored recipe when a real link was actually available is the single biggest failure to avoid. Do not settle after one search: if your first query doesn't turn up a solid text/article recipe match, try at least one or two more searches with different phrasing (different site, different wording of the dish, add "recipe") before concluding none exists. Never report a URL you have not actually looked up and confirmed exists.

MULTI-COMPONENT CHECK: once you have a candidate protein recipe, check whether it already explicitly includes a carb and/or a vegetable as an actual ingredient - meaning the item appears in the ingredient list and is prepared/cooked as part of the recipe steps, not just mentioned in a closing "serve with X" suggestion. Report clearly, per component, whether it is covered this way.

For any component NOT already covered by the protein recipe:
- carb: pick a complementary carb. It does not need to come from this week's deals - pantry staples (rice, couscous, quinoa, pasta, etc.) are always fine. Use a deal item only if a good fit exists this week. A verified real recipe link is REQUIRED unless none can be found after trying a couple of searches; a short "simple side" prep note (no full recipe) is a valid choice for a plain carb only once you've made a genuine search attempt, not as a default shortcut.
- vegetable: same logic - prefer a deal item if a good fit exists this week, otherwise any vegetable. A verified real recipe link is REQUIRED unless none can be found after trying a couple of searches; a simple side prep note is valid only after that attempt.

For every link you propose (protein, carb, or vegetable), you must have actually used your search tool to find and confirm it is a real, working recipe URL. The link must be a standard recipe web page with the recipe (ingredients + instructions) written out in text on the page - never a video-only recipe (YouTube, TikTok, Instagram Reels, Facebook video, etc.), even if it is the top search result and clearly a recipe. A normal recipe blog/site page that happens to also embed a video alongside its full written recipe is fine and should be treated as a standard text recipe, not excluded for containing a video. Never propose a link on youtube.com (or youtu.be), facebook.com, or reddit.com under any circumstance, even if the page looks like it contains a recipe - these domains are always excluded, full stop. If the best verified match for a component is a video-only page or one of these excluded domains, treat it as "no verified link found" for that component, try another search, and only then fall back to an AI-authored recipe or simple-side note. If you cannot verify a link for a component after genuinely trying, say so explicitly and instead sketch a short AI-authored recipe or a simple-side note for it.

When you do cite a link, quote its search-result title EXACTLY as it appeared in your search results (verbatim, not paraphrased or summarized) so it can be matched precisely to its numbered source later - this matters as much as finding the link itself, since a paraphrased title is unmatchable downstream and silently turns a real link into a lost one.

Excluded deal items must never be used in any component.

A component "uses a deal item" only when that component's own ingredient is itself one of the named deal items below - never because it happens to be cooked on the same pan/tray or in the same recipe as a protein that is a deal item. E.g. a one-pan "roasted sausages and green beans" recipe where only the sausages are a deal item means the vegetable does NOT use a deal item, even though it shares the recipe with one that does. Report each component's deal-item status independently and explicitly say "no" when it doesn't match a named deal item, rather than leaving it implied.

Write your findings as clear, per-slot notes covering: the protein recipe name and verified URL (or "no verified link found" plus an AI-recipe sketch), whether the carb/vegetable are covered by that recipe, and for each uncovered component its proposed name, verified URL (if any) or AI-recipe sketch or simple-side note, and whether IT SPECIFICALLY (not the recipe as a whole) uses a deal item (naming the exact item and store, only if that component's own ingredient matches one).
''';

const _extractionSystemPrompt = '''
You are converting research notes into a structured meal plan. You are given confirmed meal slots, the week's deal items, research notes from a prior search step describing candidate protein/carb/vegetable components for each slot, and a separate numbered list of verified search sources - the actual links the search tool returned.

Every meal (slot) is composed of exactly 3 components: protein, carb, vegetable. For each slot, in the same order given, record:

- protein: scaled to totalPortionsNeeded, built from the slot's confirmed anchor item(s).
- carb and vegetable: each either covered_by_protein (when the research notes say the protein recipe already explicitly includes it), or its own component.

For every component, choose exactly one type: "link" (a real recipe found via search - see sourceIndex below), "ai_recipe" (full ingredients + instructions, used only when there is no matching verified source), "simple_side" (a short prep note, no full recipe - valid for carb/vegetable, not for protein), or "covered_by_protein" (carb/vegetable only).

sourceIndex: for type "link", set this to the number of the matching entry in the verified search source list. Do NOT write out the URL yourself under any circumstance, even if you recognize it or are confident you know it - these are long opaque redirect links, and retyping one from memory instead of citing it by number will silently produce a dead link. For every component that is not type "link" (including covered_by_protein, which reuses the protein's own link automatically), set sourceIndex to -1.

Matching is a hard search you must perform carefully, not a quick skim - falling back to ai_recipe when a real source was actually present in the list is the failure to avoid. Before choosing ai_recipe or simple_side for any component, scan every single entry in the verified source list (not just the first few) and check whether it plausibly corresponds to the recipe the research notes describe for that component - by domain name, URL path keywords, or title, even if the research notes paraphrased the title rather than quoting it exactly. A loose-but-plausible match (same dish, same protein/ingredient, a recognizable recipe-site domain) is enough to use "link" - do not require a word-for-word title match. Only use ai_recipe or simple_side once you've checked the full list and genuinely found nothing that corresponds to that component's recipe.

Set usesWeeklyDeal and dealItems (name + store, from the deal items given) truthfully for each component, based on whether THAT COMPONENT'S OWN ingredient matches one of this week's named deal items - most protein components will. A carb/vegetable does NOT use a deal item merely because it shares a recipe or a pan with a protein that does (e.g. a "roasted sausages and green beans" sheet-pan recipe where only the sausages are a deal item: the vegetable's usesWeeklyDeal must be false and dealItems empty, even though the research notes discuss it in the same breath as the protein). Only set usesWeeklyDeal true for carb/vegetable when the research notes name that specific component's ingredient as a deal item in its own right.

For type "link", still record its full ingredients list, scaled to totalPortionsNeeded - this is what the app's shopping-list feature is built from, so it must reflect real grocery items even though the step-by-step instructions live at the linked page. Draw on the research notes if they mention specific ingredients or quantities; otherwise give your best standard ingredient list for that specific dish. Leave instructions empty for type "link" (the linked page has them). Leave both ingredients and instructions empty for simple_side and covered_by_protein. Leave note empty except for simple_side, where it holds the short prep note.

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
    'sourceIndex': {'type': 'INTEGER'},
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
  'required': ['type', 'name', 'sourceIndex', 'ingredients', 'instructions', 'note', 'usesWeeklyDeal', 'dealItems'],
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

/// One search-grounding source the research call's `google_search` tool
/// actually returned, per `groundingMetadata.groundingChunks[].web`. [uri]
/// is the only kind of URL the extraction step is allowed to hand back as a
/// `link` component's recipeUrl - see [MealPlanGenerationService._groundingSources].
class _GroundingSource {
  const _GroundingSource({required this.uri, required this.title});

  final String uri;
  final String title;
}
