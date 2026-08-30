import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/deal_item.dart';
import '../models/meal_history.dart';
import '../models/meal_plan_config.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';
import '../models/store_config.dart';
import '../services/ai_config_repository.dart';
import '../services/ai_deal_extraction_service.dart';
import '../services/deal_cache_repository.dart';
import '../services/deal_preference_repository.dart';
import '../services/flyer_scraper_service.dart';
import '../services/meal_history_repository.dart';
import '../services/meal_plan_config_repository.dart';
import '../services/meal_plan_draft_repository.dart';
import '../services/meal_plan_generation_service.dart';
import '../services/meal_plan_preview_service.dart';
import '../services/model_fallback_controller.dart';
import '../services/redirect_resolver.dart';
import '../services/store_config_repository.dart';
import '../utils/error_formatting.dart';
import '../utils/iso_week.dart';
import '../widgets/confirm_delete_dialog.dart';
import '../widgets/ingredient_list_dialog.dart';
import '../widgets/meal_slot_full_card.dart';
import '../widgets/rate_limit_dialog.dart';

/// Which step the screen is currently showing. "structure" is the gate step
/// reached from the deals view's "Preview meal plan" FAB (or reopened from
/// review): it lets the user validate/adjust what to plan (meal slots,
/// portions, dietary notes) before the AI call that produces "review"
/// actually runs. "review" walks the confirmed slots one meal at a time -
/// anchor items and that meal's full recipe live on the same card, so
/// there's no separate preview/full-plan screen pair to keep in sync by
/// hand.
///
/// Every forward transition between these goes through [_PlanifScreenState._pushStep],
/// which records the step being left on a back-history stack - the app
/// bar's back arrow (and the platform back gesture) pop that stack one
/// entry at a time, so "back" always means "one step back from wherever I
/// am" rather than a hardcoded jump to a fixed step.
enum _Step { fetch, deals, structure, review }

/// Opens a recipe link. Injectable so tests can avoid driving a real
/// platform URL launcher.
typedef RecipeLinkLauncher = Future<void> Function(Uri uri);

/// Default [RecipeLinkLauncher]: hands the URL to the platform's own
/// browser/app handler.
Future<void> openRecipeLink(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

const _sectionOrder = [
  DealCategory.protein,
  DealCategory.vegetables,
  DealCategory.carbs,
  DealCategory.uncategorized,
];

enum StoreFetchStatus { waiting, inProgress, done, failed }

class StoreFetchState {
  StoreFetchState(this.store);

  final StoreConfig store;
  StoreFetchStatus status = StoreFetchStatus.waiting;
  int itemCount = 0;
  String? errorMessage;
}

class PlanifScreen extends StatefulWidget {
  PlanifScreen({
    super.key,
    required this.repository,
    FlyerScraperService? scraperService,
    AiDealExtractionService? extractionService,
    AiConfigRepository? aiConfigRepository,
    DealPreferenceRepository? preferenceRepository,
    DealCacheRepository? cacheRepository,
    MealPlanConfigRepository? mealPlanConfigRepository,
    MealHistoryRepository? mealHistoryRepository,
    MealPlanDraftRepository? mealPlanDraftRepository,
    MealPlanPreviewService? previewService,
    MealPlanGenerationService? generationService,
    Duration? rateLimitWait,
    RateLimitPrompt? rateLimitPrompt,
    RecipeLinkLauncher? launchRecipeLink,
  }) : scraperService = scraperService ?? FlyerScraperService(),
       extractionService = extractionService ?? AiDealExtractionService(),
       aiConfigRepository = aiConfigRepository ?? AiConfigRepository(),
       preferenceRepository = preferenceRepository ?? DealPreferenceRepository(),
       cacheRepository = cacheRepository ?? DealCacheRepository(),
       mealPlanConfigRepository = mealPlanConfigRepository ?? MealPlanConfigRepository(),
       mealHistoryRepository = mealHistoryRepository ?? MealHistoryRepository(),
       mealPlanDraftRepository = mealPlanDraftRepository ?? MealPlanDraftRepository(),
       previewService = previewService ?? MealPlanPreviewService(),
       generationService = generationService ?? MealPlanGenerationService(resolveRecipeLink: resolveRedirectUrl),
       rateLimitWait = rateLimitWait ?? const Duration(minutes: 1),
       rateLimitPrompt = rateLimitPrompt ?? showRateLimitDialog,
       launchRecipeLink = launchRecipeLink ?? openRecipeLink;

  final StoreConfigRepository repository;
  final FlyerScraperService scraperService;
  final AiDealExtractionService extractionService;
  final AiConfigRepository aiConfigRepository;
  final DealPreferenceRepository preferenceRepository;
  final DealCacheRepository cacheRepository;
  final MealPlanConfigRepository mealPlanConfigRepository;
  final MealHistoryRepository mealHistoryRepository;
  final MealPlanDraftRepository mealPlanDraftRepository;
  final MealPlanPreviewService previewService;
  final MealPlanGenerationService generationService;

  /// How long [ModelFallbackController] waits before its one automatic
  /// retry on a rate-limited call. Injectable so tests don't have to wait.
  final Duration rateLimitWait;

  /// Asks what to do when a call is still rate limited after that retry.
  /// Injectable so tests can avoid driving a real dialog.
  final RateLimitPrompt rateLimitPrompt;

  /// Opens a recipe link. Injectable so tests can avoid driving a real
  /// platform URL launcher.
  final RecipeLinkLauncher launchRecipeLink;

  @override
  State<PlanifScreen> createState() => _PlanifScreenState();
}

class _PlanifScreenState extends State<PlanifScreen> {
  List<StoreFetchState> _states = [];
  List<DealItem> _items = [];
  bool _isRunning = false;
  bool _hasRun = false;
  String? _storeFilter;
  DealCategory? _categoryFilter;
  String? _apiKey;
  List<String> _models = [];
  List<String> _groundingModels = [];
  MealPlanPreview? _preview;
  MealPlanConfig? _mealPlanConfig;
  // Draft edited on the structure step, separate from _mealPlanConfig (the
  // config the currently-shown preview, if any, was actually generated
  // from) so navigating to the structure step and cancelling out without
  // confirming never touches what's already on screen.
  MealPlanConfig? _structureDraft;
  bool _isPreviewLoading = false;
  _Step _step = _Step.fetch;
  // Back-history stack _pushStep records onto and _goBack pops from - see
  // the _Step doc comment. Empty exactly when _step is _Step.fetch: that's
  // the flow's true root, and every path back down to it necessarily
  // drains the stack (each pop removes exactly one forward push).
  final List<_Step> _history = [];
  final Set<int> _regeneratingSlots = {};
  // One entry per _preview slot, filled in as each meal's recipe is
  // generated on the review step - null means "not generated yet". Kept
  // parallel to _preview!.slots rather than a sparse map so index lookups
  // (current review slot, anchor edits invalidating just their own slot)
  // stay simple.
  List<MealSlotFull?> _slotRecipes = [];
  int _reviewIndex = 0;
  final Set<int> _generatingRecipeSlots = {};
  // Which of the two AI calls behind _generateSlotRecipe is currently in
  // flight for a given slot ('research' or 'extraction', matching
  // MealPlanGenerationService's onPhase callback) - the research step
  // (searching for and verifying real recipe links) is the slower of the
  // two, so surfacing which one is running keeps the wait from reading as
  // a stuck spinner.
  final Map<int, String> _recipeGenerationPhase = {};
  bool _isSavingWeek = false;

  bool get _allSlotsGenerated => _slotRecipes.isNotEmpty && _slotRecipes.every((s) => s != null);

  List<MealSlotFull> get _generatedSlots => _slotRecipes.whereType<MealSlotFull>().toList();

  // Moves forward to [step], recording the step being left so a later
  // _goBack() (or the platform back gesture) returns to exactly that step -
  // not a fixed one. A no-op on the step itself (e.g. "regenerate all
  // suggestions" while already reviewing) leaves the history untouched,
  // since nothing was actually left.
  void _pushStep(_Step step) {
    if (_step != step) _history.add(_step);
    _step = step;
  }

  void _goBack() {
    if (_history.isEmpty) return;
    setState(() => _step = _history.removeLast());
  }

  // Names the step the back arrow/gesture is about to land on, so its
  // tooltip (and screen-reader announcement) describes what "back" actually
  // does at the current depth instead of a single fixed caption.
  String _stepLabel(_Step step) => switch (step) {
    _Step.fetch => 'fetch deals',
    _Step.deals => 'deals',
    _Step.structure => 'meal plan structure',
    _Step.review => 'meal plan review',
  };

  @override
  void initState() {
    super.initState();
    _loadCachedItems();
    _loadDraft();
  }

  // Restores whatever generated preview/recipes survived from before a
  // crash, refresh, or reclaimed tab (see issue #35) - saved incrementally
  // by _saveDraft after each successful generation step. Runs independently
  // of _loadCachedItems: the draft's own anchors/recipes stand on their own
  // regardless of whether the underlying deal cache also loaded.
  Future<void> _loadDraft() async {
    final draft = await widget.mealPlanDraftRepository.load();
    if (draft == null) return;
    if (!mounted) return;
    // A real fetch that started while this load was still in flight always
    // wins, same reasoning as _loadCachedItems.
    if (_isRunning) return;
    // Restoring straight into the review step re-enables actions (regenerate,
    // per-slot recipe generation) that need an API key - _loadCachedItems
    // only sets _apiKey as a side effect of a non-empty deal cache, so load
    // it directly here too. Otherwise a draft restored with an empty deal
    // cache would leave those actions silently doing nothing instead of
    // prompting to set a key, unlike every other entry point that reaches them.
    final apiKey = _apiKey ?? await widget.aiConfigRepository.loadApiKey();
    final models = apiKey.isEmpty ? _models : await widget.aiConfigRepository.loadModels();
    final groundingModels = apiKey.isEmpty ? _groundingModels : await widget.aiConfigRepository.loadGroundingModels();
    if (!mounted) return;
    if (_isRunning) return;
    setState(() {
      _mealPlanConfig = draft.config;
      _preview = draft.preview;
      _slotRecipes = draft.slotRecipes;
      _pushStep(_Step.review);
      _reviewIndex = 0;
      if (apiKey.isNotEmpty) {
        _apiKey = apiKey;
        _models = models;
        _groundingModels = groundingModels;
      }
    });
  }

  // Persists the current preview + per-slot recipes after every successful
  // generation step, so there's always a recoverable checkpoint no more than
  // one step old. Best-effort: a failed save leaves the in-progress work
  // fully usable for this session, just not recoverable if the tab is lost
  // right after.
  Future<void> _saveDraft() async {
    final config = _mealPlanConfig;
    final preview = _preview;
    if (config == null || preview == null) return;
    await widget.mealPlanDraftRepository
        .save(MealPlanDraft(config: config, preview: preview, slotRecipes: _slotRecipes))
        .catchError((_) {
          // Non-fatal - see comment above.
        });
  }

  // Shows the last fetch's results immediately on open, so the user isn't
  // forced to re-fetch every time just to see deals they already pulled.
  Future<void> _loadCachedItems() async {
    final cached = await widget.cacheRepository.load();
    if (cached.isEmpty) return;
    final withPreferences = await _applyPreferences(cached);
    // Loaded alongside the cache so _hasRun implies _apiKey is set, same as
    // the _fetchAll path - otherwise Step 2's "Preview" button would render
    // enabled but silently do nothing until an actual fetch runs.
    final apiKey = await widget.aiConfigRepository.loadApiKey();
    final models = apiKey.isEmpty ? <String>[] : await widget.aiConfigRepository.loadModels();
    final groundingModels = apiKey.isEmpty ? <String>[] : await widget.aiConfigRepository.loadGroundingModels();
    if (!mounted) return;
    // A real fetch that started (and possibly finished) while this cache
    // load was still in flight always wins - applying stale cached data on
    // top of it would silently discard fresher results.
    if (_isRunning || _hasRun) return;
    setState(() {
      _items = withPreferences;
      _hasRun = true;
      // Guarded rather than an unconditional _pushStep: _loadDraft runs
      // concurrently in initState and can already have moved past fetch
      // (straight to review) by the time this resolves - advancing to
      // deals here must never clobber that.
      if (_step == _Step.fetch) _pushStep(_Step.deals);
      if (apiKey.isNotEmpty) {
        _apiKey = apiKey;
        _models = models;
        _groundingModels = groundingModels;
      }
    });
  }

  Future<void> _fetchAll() async {
    final apiKey = await widget.aiConfigRepository.loadApiKey();
    if (apiKey.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }

    final models = await widget.aiConfigRepository.loadModels();
    final groundingModels = await widget.aiConfigRepository.loadGroundingModels();
    final stores = await widget.repository.load();
    if (!mounted) return;
    setState(() {
      _states = stores.map((s) => StoreFetchState(s)).toList();
      _items = [];
      _isRunning = true;
      _hasRun = false;
      _storeFilter = null;
      _categoryFilter = null;
      _apiKey = apiKey;
      _models = models;
      _groundingModels = groundingModels;
    });

    // Fetched one store at a time, not in parallel: every store hits the
    // same AI API key, and firing them all at once was tripping Gemini's
    // rate limit (HTTP 429) far more often than fetching sequentially does.
    final items = <DealItem>[];
    for (final state in _states) {
      items.addAll(await _fetchStore(state, apiKey, models));
    }

    // Every store failing leaves nothing to show for this reload - keep
    // whatever was cached/selected before rather than wiping it out for an
    // empty result.
    var withPreferences = items;
    if (items.isNotEmpty) {
      // An explicit reload starts over: last fetch's priority/excluded
      // selections were made against items that are about to be replaced, so
      // keeping them around would silently misapply old choices to new
      // deals. Done only once there are actual new items to apply it to.
      await widget.preferenceRepository.clearAll();
      withPreferences = await _applyPreferences(items);
      try {
        await widget.cacheRepository.save(withPreferences);
      } catch (_) {
        // Non-fatal: the freshly fetched items are still shown for this
        // session, just not persisted for the next time the screen opens.
      }
    }
    if (!mounted) return;
    setState(() {
      _items = withPreferences;
      _isRunning = false;
      _hasRun = true;
      // Always reached with _step still _Step.fetch - the "Fetch deals"
      // button that triggers this only renders on that step - so this is a
      // plain forward push, same as the cache-load path.
      _pushStep(_Step.deals);
    });
  }

  Future<List<DealItem>> _applyPreferences(List<DealItem> items) async {
    final saved = await widget.preferenceRepository.loadAll();
    if (saved.isEmpty) return items;
    return items.map((item) {
      final preference = saved[item.preferenceKey];
      return preference == null ? item : item.copyWith(preference: preference);
    }).toList();
  }

  Future<void> _togglePreference(DealItem item) async {
    final next = item.preference.next;
    final updated = item.copyWith(preference: next);
    setState(() {
      final index = _items.indexOf(item);
      if (index != -1) _items[index] = updated;
    });
    await widget.preferenceRepository.setPreference(item.preferenceKey, next);
  }

  // Config comes from the structure step's confirmed draft on a first
  // generation; omitted (reloaded from the repository, as before the
  // structure step existed) when the existing "Regenerate preview" action
  // re-runs the call against whatever was last confirmed.
  Future<void> _generatePreview({MealPlanConfig? config}) async {
    if (_isPreviewLoading || _regeneratingSlots.isNotEmpty) return;
    final apiKey = _apiKey;
    if (apiKey == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }

    final resolvedConfig = config ?? await widget.mealPlanConfigRepository.load();
    final recentlyUsed = await widget.mealHistoryRepository.recentlyUsed(
      diversityWindowDays: resolvedConfig.diversityWindowDays,
    );
    setState(() => _isPreviewLoading = true);

    final controller = ModelFallbackController(models: _models, waitBeforeRetry: widget.rateLimitWait);
    try {
      final preview = await controller.run(
        attempt: (model) => widget.previewService.previewMealPlan(
          apiKey: apiKey,
          mealSlots: resolvedConfig.mealSlots,
          portionsPerMeal: resolvedConfig.portionsPerMeal,
          items: _items,
          recentlyUsed: recentlyUsed,
          dietaryNotes: resolvedConfig.dietaryNotes,
          model: model,
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _mealPlanConfig = resolvedConfig;
        _isPreviewLoading = false;
        // A no-op push when this is "regenerate all suggestions" from
        // review itself (already the current step); a real forward push
        // when this follows confirming the structure step.
        _pushStep(_Step.review);
        _reviewIndex = 0;
        // A freshly (re)generated preview can have entirely different
        // anchors, and possibly a different number of slots - any
        // per-slot recipes already generated were built against the old
        // ones, so they're stale. Reset to one null entry per new slot
        // rather than trying to carry old recipes forward by index.
        _slotRecipes = List<MealSlotFull?>.filled(preview.slots.length, null);
      });
      await _saveDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPreviewLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not generate preview: ${stripExceptionPrefix(e)}')));
    }
  }

  // Opens the structure step from the deals view's FAB: the same API-key
  // check _generatePreview used to do up front, since nothing past this
  // point can proceed without one either. Seeds the draft from whatever
  // config the current preview (if any) was generated from, so revisiting
  // the structure step to tweak and regenerate starts from the confirmed
  // state rather than silently reloading the repository's copy.
  Future<void> _openStructureStep() async {
    final apiKey = _apiKey;
    if (apiKey == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }
    final config = _mealPlanConfig ?? await widget.mealPlanConfigRepository.load();
    if (!mounted) return;
    setState(() {
      _structureDraft = config;
      // Pushes whichever step this was actually opened from - deals (via
      // the FAB) or review (via the "Edit meal plan structure" action) -
      // so back lands on the right one either way.
      _pushStep(_Step.structure);
    });
  }

  // Persists the structure step's edits so they're what Config screen and
  // any future regenerate call see too, then runs the same generation the
  // old direct-from-FAB flow used to.
  Future<void> _confirmStructureAndGeneratePreview() async {
    final draft = _structureDraft;
    if (draft == null || _isPreviewLoading) return;
    await widget.mealPlanConfigRepository.save(draft);
    if (!mounted) return;
    await _generatePreview(config: draft);
  }

  void _updateStructurePortions(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    setState(() => _structureDraft = _structureDraft!.copyWith(portionsPerMeal: parsed));
  }

  void _updateStructureDiversity(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    setState(() => _structureDraft = _structureDraft!.copyWith(diversityWindowDays: parsed));
  }

  void _updateStructureDietaryNotes(String value) {
    setState(() => _structureDraft = _structureDraft!.copyWith(dietaryNotes: value));
  }

  void _addStructureSlot() {
    final slots = [
      ..._structureDraft!.mealSlots,
      MealSlot(id: '${DateTime.now().millisecondsSinceEpoch}', mealType: MealType.lunch, protein: 'meat', count: 1),
    ];
    setState(() => _structureDraft = _structureDraft!.copyWith(mealSlots: slots));
  }

  void _updateStructureSlot(int index, MealSlot slot) {
    final slots = [..._structureDraft!.mealSlots];
    slots[index] = slot;
    setState(() => _structureDraft = _structureDraft!.copyWith(mealSlots: slots));
  }

  Future<void> _removeStructureSlot(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Remove this meal slot?',
      content: 'This removes the meal slot from this plan.',
    );
    if (!confirmed || !mounted) return;
    final slots = [..._structureDraft!.mealSlots]..removeAt(index);
    setState(() => _structureDraft = _structureDraft!.copyWith(mealSlots: slots));
  }

  // Re-runs the AI call for just this one slot and splices the result back
  // into _preview, leaving every other slot's anchors/note untouched.
  Future<void> _regenerateSlot(int index) async {
    final apiKey = _apiKey;
    final config = _mealPlanConfig;
    if (apiKey == null || config == null || _isPreviewLoading || _regeneratingSlots.contains(index)) return;

    setState(() => _regeneratingSlots.add(index));

    // Every other slot's current anchors, so the regenerated slot doesn't
    // duplicate an ingredient another slot is already using - the AI only
    // sees the one slot being regenerated, unlike the full-plan generate
    // call where every slot (and thus every other slot's picks) is visible
    // in the same request.
    final alreadyUsedAnchors = [
      for (var i = 0; i < _preview!.slots.length; i++)
        if (i != index) ..._preview!.slots[i].anchorItems,
    ];
    final recentlyUsed = await widget.mealHistoryRepository.recentlyUsed(
      diversityWindowDays: config.diversityWindowDays,
    );

    final controller = ModelFallbackController(models: _models, waitBeforeRetry: widget.rateLimitWait);
    try {
      final result = await controller.run(
        attempt: (model) => widget.previewService.previewMealPlan(
          apiKey: apiKey,
          mealSlots: [config.mealSlots[index]],
          portionsPerMeal: config.portionsPerMeal,
          items: _items,
          alreadyUsedAnchors: alreadyUsedAnchors,
          recentlyUsed: recentlyUsed,
          dietaryNotes: config.dietaryNotes,
          model: model,
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() {
        final slots = [..._preview!.slots];
        slots[index] = result.slots.single;
        _preview = MealPlanPreview(slots: slots);
        _regeneratingSlots.remove(index);
        // Only this slot's anchors changed - any recipe already generated
        // for it no longer matches, but every other slot's recipe is still
        // good.
        _slotRecipes[index] = null;
      });
      await _saveDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() => _regeneratingSlots.remove(index));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not regenerate these suggestions: ${stripExceptionPrefix(e)}')));
    }
  }

  // Normalized by name alone, not name+store: the same ingredient sold at
  // two different stores (e.g. "Brocoli" at IGA and "Brocoli" at Metro)
  // still counts as reusing it, so this can't dedupe on store too.
  String _anchorNameKey(String name) => name.trim().toLowerCase();

  // Every anchor item currently used anywhere in the preview, across every
  // slot - an ingredient shouldn't anchor more than one slot, so neither the
  // swap nor the add picker should offer one already spoken for elsewhere.
  Set<String> _usedAnchorKeys() => {
    for (final slot in _preview!.slots)
      for (final anchor in slot.anchorItems) _anchorNameKey(anchor.name),
  };

  Future<void> _swapAnchorItem(int slotIndex, AnchorItem current) async {
    final usedKeys = _usedAnchorKeys();
    final available = _items
        .where((item) => item.preference != DealPreference.excluded)
        .where((item) => !usedKeys.contains(_anchorNameKey(item.name)))
        .toList();
    final selected = await showDialog<DealItem>(context: context, builder: (_) => _AnchorPickerDialog(items: available));
    if (selected == null) return;

    setState(() {
      final slots = [..._preview!.slots];
      final slot = slots[slotIndex];
      final anchors = slot.anchorItems
          .map((a) => identical(a, current) ? AnchorItem(name: selected.name, store: selected.storeName) : a)
          .toList();
      slots[slotIndex] = slot.copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  Future<void> _addAnchorItem(int slotIndex) async {
    final usedKeys = _usedAnchorKeys();
    final available = _items
        .where((item) => item.preference != DealPreference.excluded)
        .where((item) => !usedKeys.contains(_anchorNameKey(item.name)))
        .toList();
    final selected = await showDialog<DealItem>(
      context: context,
      builder: (_) => _AnchorPickerDialog(items: available, title: 'Add anchor item'),
    );
    if (selected == null) return;

    setState(() {
      final slots = [..._preview!.slots];
      final anchors = [...slots[slotIndex].anchorItems, AnchorItem(name: selected.name, store: selected.storeName)];
      slots[slotIndex] = slots[slotIndex].copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  Future<void> _removeAnchorItem(int slotIndex, AnchorItem anchor) async {
    setState(() {
      final slots = [..._preview!.slots];
      final slot = slots[slotIndex];
      final anchors = slot.anchorItems.where((a) => !identical(a, anchor)).toList();
      slots[slotIndex] = slot.copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  void _jumpToMeal(int index) => setState(() => _reviewIndex = index);

  // The review step's one action for turning a meal's confirmed anchors
  // into (or back into, on a re-run after an anchor edit) a full recipe.
  // Doubles as both "generate" and "regenerate" for a slot - it's the same
  // call either way - so there's only one code path to keep in sync with
  // the card's anchors, unlike the old preview/full-plan split.
  Future<void> _generateSlotRecipe(int index) async {
    final apiKey = _apiKey;
    final preview = _preview;
    if (apiKey == null ||
        preview == null ||
        _isPreviewLoading ||
        _regeneratingSlots.contains(index) ||
        _generatingRecipeSlots.contains(index)) {
      return;
    }

    setState(() => _generatingRecipeSlots.add(index));

    // Every other meal this week, so the AI generating just this one slot
    // still knows what the rest of the week looks like - deal items can't
    // collide across slots regardless (anchors are already kept distinct),
    // but nothing else stops two independently-generated recipes from
    // landing on the same dish or prep style without this.
    final otherMeals = [
      for (var i = 0; i < preview.slots.length; i++)
        if (i != index)
          OtherWeekMeal(
            mealType: preview.slots[i].mealType,
            protein: preview.slots[i].protein,
            anchorItems: preview.slots[i].anchorItems,
            recipeNames: switch (_slotRecipes[i]) {
              null => const [],
              final recipe => [recipe.proteinComponent.name, recipe.carbComponent.name, recipe.vegetableComponent.name],
            },
          ),
    ];

    final dietaryNotes = _mealPlanConfig?.dietaryNotes ?? '';
    final controller = ModelFallbackController(models: _models, waitBeforeRetry: widget.rateLimitWait);
    try {
      final result = await controller.run(
        attempt: (model) => widget.generationService.generateMealPlan(
          apiKey: apiKey,
          slots: [preview.slots[index]],
          items: _items,
          dietaryNotes: dietaryNotes,
          model: model,
          groundingModels: _groundingModels,
          otherMeals: otherMeals,
          onPhase: (phase) {
            if (!mounted) return;
            setState(() => _recipeGenerationPhase[index] = phase);
          },
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() {
        _slotRecipes[index] = result.slots.single;
        _generatingRecipeSlots.remove(index);
        _recipeGenerationPhase.remove(index);
      });
      await _saveDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generatingRecipeSlots.remove(index);
        _recipeGenerationPhase.remove(index);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not generate this recipe: ${stripExceptionPrefix(e)}')));
    }
  }

  // Explicit action only - nothing is saved automatically on generation, so
  // re-generating or tweaking a plan before saving never creates a duplicate
  // history entry. Saving again for the same ISO week overwrites that
  // week's entry rather than appending a new one.
  Future<void> _saveWeekPlan() async {
    if (!_allSlotsGenerated || _isSavingWeek) return;

    setState(() => _isSavingWeek = true);
    final entry = MealHistoryEntry(weekId: isoWeekId(DateTime.now()), savedAt: DateTime.now(), slots: _generatedSlots);
    await widget.mealHistoryRepository.saveWeek(entry);
    // The plan is committed to history now, so the draft has served its
    // purpose - clearing it means reopening the app won't resurface a plan
    // that's already saved. Best-effort like _saveDraft: the week is already
    // safely in history at this point, so a failure here shouldn't block
    // finishing the save or leave _isSavingWeek stuck true.
    await widget.mealPlanDraftRepository.clear().catchError((_) {
      // Non-fatal - see comment above.
    });
    if (!mounted) return;
    setState(() => _isSavingWeek = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved this week\'s plan to history.')));
  }

  Future<void> _openRecipeLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await widget.launchRecipeLink(uri);
    } catch (_) {
      // Non-fatal: if the platform can't launch it (e.g. no browser handler
      // available), the user still has the URL visible in the card to copy.
    }
  }

  Future<void> _retryStore(StoreFetchState state) async {
    final apiKey = _apiKey;
    if (apiKey == null || _isRunning) return;

    setState(() => _isRunning = true);
    final rawItems = await _fetchStore(state, apiKey, _models);
    final items = await _applyPreferences(rawItems);
    final merged = [..._items.where((item) => item.storeName != state.store.name), ...items];
    try {
      await widget.cacheRepository.save(merged);
    } catch (_) {
      // Non-fatal: the merged items are still shown for this session, just
      // not persisted for the next time the screen opens.
    }
    if (!mounted) return;
    setState(() {
      _items = merged;
      // A retry can drop the filtered store/category to zero items, which
      // would otherwise leave a filter pointing at something _buildResults
      // can no longer find - reset it rather than showing an unexplained
      // empty list.
      if (_storeFilter != null && !_items.any((item) => item.storeName == _storeFilter)) {
        _storeFilter = null;
      }
      if (_categoryFilter != null && !_items.any((item) => item.category == _categoryFilter)) {
        _categoryFilter = null;
      }
      _isRunning = false;
    });
  }

  // items accumulates outside the try block (and outside each chunk's
  // ModelFallbackController.run) on purpose: a chunk is retried with only
  // that chunk's pages, so a later chunk failing never re-sends - or loses -
  // an earlier chunk's already-extracted items.
  Future<List<DealItem>> _fetchStore(StoreFetchState state, String apiKey, List<String> models) async {
    if (mounted) setState(() => state.status = StoreFetchStatus.inProgress);
    final items = <DealItem>[];
    // Remaining models to try, trimmed to start at whichever model actually
    // succeeded for the previous chunk - a chunked store's later chunks
    // otherwise forget a model already skipped past and re-attempt (and
    // re-prompt for) it from scratch every time.
    var remainingModels = models;
    try {
      final pages = await widget.scraperService.fetchPages(state.store);
      for (var start = 0; start < pages.length; start += AiDealExtractionService.maxPagesPerCall) {
        final end = (start + AiDealExtractionService.maxPagesPerCall).clamp(0, pages.length);
        final chunk = pages.sublist(start, end);
        final controller = ModelFallbackController(models: remainingModels, waitBeforeRetry: widget.rateLimitWait);
        var usedModel = remainingModels.first;
        items.addAll(
          await controller.run(
            attempt: (model) {
              usedModel = model;
              return widget.extractionService.extractItems(
                apiKey: apiKey,
                storeName: state.store.name,
                pages: chunk,
                model: model,
              );
            },
            onRateLimited: ({required currentModel, nextModel}) {
              if (!mounted) return Future.value(RateLimitChoice.retrySame);
              return widget.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
            },
          ),
        );
        remainingModels = remainingModels.sublist(remainingModels.indexOf(usedModel));
      }
      if (mounted) {
        setState(() {
          state.status = StoreFetchStatus.done;
          state.itemCount = items.length;
        });
      }
      return items;
    } catch (e) {
      if (mounted) {
        setState(() {
          state.status = StoreFetchStatus.failed;
          state.errorMessage = _shortReason(e);
          // items already extracted from earlier chunks are still returned
          // and merged into the results below, so the status needs to say
          // so - otherwise "failed" would read as "nothing came of this"
          // when some items actually did.
          state.itemCount = items.length;
        });
      }
      return items;
    }
  }

  String _shortReason(Object error) {
    final message = stripExceptionPrefix(error);
    return message.length > 80 ? '${message.substring(0, 80)}…' : message;
  }

  @override
  Widget build(BuildContext context) {
    // The review step's Back/Generate/Next/Save CTA lives in a persistent
    // footer instead of at the bottom of the card - it stays reachable
    // without scrolling as the user steps through each meal.
    final showReviewBar = _step == _Step.review && _preview != null;
    // Mirrors the review footer: pinned CTA for the structure step, shown
    // only while that step is what's on screen.
    final showStructureBar = _step == _Step.structure && _structureDraft != null;
    // The preview FAB only exists to get a first preview started - once one
    // exists, getting back to it (or regenerating it) goes through the app
    // bar's view toggle and regenerate action instead.
    final showPreviewFab = _step == _Step.deals && _items.isNotEmpty && _preview == null;
    return PopScope(
      // Lets the platform back gesture/button (browser back in a PWA
      // context included) pop this flow's own step history one level at a
      // time, same as the app bar's back arrow - only once that history is
      // empty (already on the fetch step) does a back gesture fall through
      // to actually leaving the screen.
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Planif'),
          // The back arrow only exists once there's somewhere to pop back
          // to - on the fetch step (the flow's root) _history is always
          // empty, so there's nothing for it to do.
          leading: _history.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back to ${_stepLabel(_history.last)}',
                  onPressed: _goBack,
                )
              : null,
          actions: _step != _Step.fetch ? _buildAppBarActions() : null,
        ),
        body: _step == _Step.fetch ? _buildFetchStep() : _buildBrowseStep(),
        floatingActionButton: showPreviewFab ? _buildPreviewFab() : null,
        bottomNavigationBar: showStructureBar
            ? _buildStructureBar()
            : showReviewBar
            ? _buildReviewBar()
            : null,
      ),
    );
  }

  bool get _reviewBusy =>
      _isPreviewLoading || _regeneratingSlots.isNotEmpty || _generatingRecipeSlots.isNotEmpty || _isSavingWeek;

  // Everything that used to live in a second chrome row now lives here
  // instead: a compact view-mode toggle once there's a preview to switch
  // to, the priority/excluded summary and a filter action (badged when a
  // store filter is active) while browsing deals, and a regenerate action
  // while reviewing meals.
  List<Widget> _buildAppBarActions() {
    return [
      // Hidden while the structure step is on screen: it isn't one of the
      // toggle's own segments (deals/review), so showing it here would
      // render with nothing selected.
      if (_preview != null && _step != _Step.structure) _buildViewModeToggle(),
      if (_step == _Step.deals && _items.isNotEmpty) _buildPreferenceSummary(),
      if (_step == _Step.deals && _items.isNotEmpty) _buildFilterButton(),
      if (_step == _Step.review && _preview != null) _buildEditStructureButton(),
      if (_step == _Step.review && _preview != null) _buildRegenerateButton(),
      if (_step == _Step.review && _allSlotsGenerated) _buildIngredientListButton(),
      const SizedBox(width: 4),
    ];
  }

  // Lets the user get back to the structure step (to change slot counts,
  // portions, or dietary notes) without going all the way back to the
  // deals view and re-triggering the FAB - it just re-seeds the draft from
  // whatever config produced the preview currently on screen.
  Widget _buildEditStructureButton() {
    return IconButton(icon: const Icon(Icons.tune), tooltip: 'Edit meal plan structure', onPressed: _reviewBusy ? null : _openStructureStep);
  }

  Widget _buildIngredientListButton() {
    return IconButton(
      icon: const Icon(Icons.receipt_long_outlined),
      tooltip: 'Extract ingredient list',
      onPressed: () => showIngredientListDialog(context, _generatedSlots),
    );
  }

  // Immediate feedback that tapping an item actually did something -
  // visible without opening the filter sheet, unlike the store filter and
  // category jump-list it sits next to.
  Widget _buildPreferenceSummary() {
    final priorityCount = _items.where((item) => item.preference == DealPreference.priority).length;
    final excludedCount = _items.where((item) => item.preference == DealPreference.excluded).length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '$priorityCount priority, $excludedCount excluded',
        style: Theme.of(context).textTheme.labelMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildViewModeToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SegmentedButton<_Step>(
        segments: const [
          ButtonSegment(value: _Step.deals, icon: Icon(Icons.shopping_bag_outlined), tooltip: 'Deal items'),
          ButtonSegment(value: _Step.review, icon: Icon(Icons.restaurant_menu), tooltip: 'Meal plan'),
        ],
        selected: {_step},
        showSelectedIcon: false,
        // A lateral switch, not a step "forward" in the usual sense - but
        // routing it through _pushStep still records where it came from, so
        // the back arrow can undo a toggle tap the same way it undoes any
        // other transition.
        onSelectionChanged: (selected) => setState(() => _pushStep(selected.first)),
        style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
      ),
    );
  }

  // Badged only for the store filter - priority/excluded already has its
  // own always-visible summary next to this button, so badging for that
  // too would just be a redundant signal for the same thing.
  Widget _buildFilterButton() {
    final active = _storeFilter != null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(icon: const Icon(Icons.tune), tooltip: 'Filters', onPressed: _openFilterSheet),
        if (active)
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.error, shape: BoxShape.circle),
            ),
          ),
      ],
    );
  }

  // Re-rolls every slot's suggested anchors at once (and clears every
  // generated recipe with them, since a slot's recipe is only ever
  // regenerated one at a time via the review card itself) - a fresh start
  // for the whole week, as opposed to the per-card refresh icon which only
  // touches the one meal it's on.
  Widget _buildRegenerateButton() {
    return IconButton(
      icon: _isPreviewLoading
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh),
      tooltip: 'Regenerate all suggestions',
      onPressed: _reviewBusy ? null : _generatePreview,
    );
  }

  Widget _buildPreviewFab() {
    return FloatingActionButton.extended(
      onPressed: _openStructureStep,
      icon: const Icon(Icons.restaurant_menu),
      label: const Text('Preview meal plan'),
    );
  }

  // Step 1: fetching deals is its own screen, not a button sharing space
  // with everything else - so there's nothing above it competing for room,
  // and nothing to fetch again until the user explicitly steps back to it.
  Widget _buildFetchStep() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_states.isNotEmpty && _isRunning)
                ..._states.map(_buildStatusRow)
              else if (_items.isNotEmpty) ...[
                // Reached by stepping back from deals/structure/review, not
                // a cold start - _items is still whatever was last fetched
                // or loaded from cache, sitting untouched in memory. A full
                // re-fetch re-runs the entire AI extraction pipeline, so
                // this offers the lighter way back into it.
                Icon(Icons.shopping_bag_outlined, size: 40, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                Text(
                  '${_items.length} deal item${_items.length == 1 ? '' : 's'} already loaded.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _pushStep(_Step.deals)),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('View loaded deals'),
                ),
              ] else ...[
                Icon(Icons.storefront_outlined, size: 40, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                const Text('Press "Fetch deals" to load flyer items.', textAlign: TextAlign.center),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isRunning ? null : _fetchAll,
                icon: _isRunning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                label: Text(_isRunning ? 'Fetching…' : 'Fetch deals'),
                style: FilledButton.styleFrom(minimumSize: const Size(220, 48)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Step 2: browsing what was fetched (deals/preview/full plan). Reached
  // once there's something to browse, either from a completed fetch or from
  // cache - _hasRun is always true here, so unlike the old single-screen
  // layout this no longer needs to branch on it.
  Widget _buildBrowseStep() {
    return Column(
      children: [
        if (_states.isNotEmpty) ...[_buildStatusSummary(), const Divider(height: 1)],
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_step == _Step.structure && _structureDraft != null) return _buildStructureStep();
    if (_step == _Step.review && _preview != null) return _buildReviewStep();
    return _buildResults();
  }

  // Stores are fetched one at a time, so a store further down the queue can
  // sit in waiting while an earlier one is inProgress - both render the
  // same "still to come" spinner row.
  Widget _buildStatusRow(StoreFetchState state) {
    final (icon, trailingText) = switch (state.status) {
      StoreFetchStatus.waiting || StoreFetchStatus.inProgress => (
        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        'Fetching…',
      ),
      StoreFetchStatus.done => (
        Icon(
          state.itemCount > 0 ? Icons.check_circle : Icons.warning,
          color: state.itemCount > 0 ? Colors.green : Colors.amber.shade700,
        ),
        '${state.itemCount} items',
      ),
      StoreFetchStatus.failed => (
        const Icon(Icons.error, color: Colors.red),
        state.itemCount > 0
            ? '${state.itemCount} items kept, then failed: ${state.errorMessage ?? "Failed"}'
            : state.errorMessage ?? 'Failed',
      ),
    };
    return ListTile(leading: icon, title: Text(state.store.name), trailing: Text(trailingText));
  }

  Widget _buildStatusSummary() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: _states.map(_buildStatusChip).toList(),
      ),
    );
  }

  // Called once _hasRun is true. Every store has settled to done or failed
  // at that point, except one that's mid-retry via _retryStore, which shows
  // as inProgress.
  Widget _buildStatusChip(StoreFetchState state) {
    if (state.status == StoreFetchStatus.failed) {
      final label = state.itemCount > 0
          ? '${state.store.name} · ${state.itemCount} kept, failed, tap to retry'
          : '${state.store.name} · failed, tap to retry';
      return ActionChip(
        avatar: const Icon(Icons.refresh, size: 16, color: Colors.red),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        tooltip: 'Retry ${state.store.name}',
        onPressed: _isRunning ? null : () => _retryStore(state),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        side: const BorderSide(color: Colors.red),
      );
    }
    if (state.status == StoreFetchStatus.done) {
      final hasDeals = state.itemCount > 0;
      return Chip(
        avatar: Icon(
          hasDeals ? Icons.check_circle : Icons.warning,
          size: 16,
          color: hasDeals ? Colors.green : Colors.amber.shade700,
        ),
        label: Text('${state.store.name} · ${state.itemCount}', style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      );
    }
    return Chip(
      avatar: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      label: Text('${state.store.name} · retrying…', style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildResults() {
    if (!_hasRun) {
      return const Center(child: Text('Press "Fetch deals" to load flyer items.'));
    }
    if (_items.isEmpty) {
      return const Center(child: Text('No items found.'));
    }

    final filtered = _filteredItems;
    // Both filters together can leave nothing to show (e.g. a store that
    // never carries any deals in the selected category) - unlike the old
    // jump-to-category behavior, an actual filter can legitimately empty
    // the list, so this has its own message rather than assuming filtered
    // is never empty.
    if (filtered.isEmpty) {
      return const Center(child: Text('No items match the current filters.'));
    }

    final grouped = <DealCategory, List<DealItem>>{};
    for (final item in filtered) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    final presentCategories = _presentCategories(filtered);

    // Store/category/priority filtering now lives in the filter sheet (see
    // _openFilterSheet) instead of always-on rows above the list, so this
    // is just the list itself.
    return ListView(
      children: [
        for (final category in presentCategories) ...[
          _buildSectionHeader(category),
          ..._coverFirst(grouped[category]!).map(_buildItemTile),
        ],
      ],
    );
  }

  List<String> get _storeNames => _items.map((item) => item.storeName).toSet().toList()..sort();

  List<DealItem> get _storeFiltered =>
      _storeFilter == null ? _items : _items.where((item) => item.storeName == _storeFilter).toList();

  // Store and category filters compose: the category filter narrows
  // whatever the store filter already narrowed down to, the same way the
  // category options offered in the sheet are themselves scoped to the
  // current store filter.
  List<DealItem> get _filteredItems {
    final storeFiltered = _storeFiltered;
    return _categoryFilter == null
        ? storeFiltered
        : storeFiltered.where((item) => item.category == _categoryFilter).toList();
  }

  List<DealCategory> _presentCategories(List<DealItem> filtered) {
    final grouped = <DealCategory, List<DealItem>>{};
    for (final item in filtered) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    return [
      for (final category in _sectionOrder)
        if ((grouped[category] ?? const []).isNotEmpty) category,
    ];
  }

  // Opens the filter sheet: priority/excluded summary, store filter and
  // category filter all live here now instead of always-on rows above the
  // deals list - they only cost screen space while actually in use.
  void _openFilterSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(builder: (context, setModalState) => _buildFilterSheetContent(setModalState)),
    );
  }

  Widget _buildFilterSheetContent(StateSetter setModalState) {
    final priorityCount = _items.where((item) => item.preference == DealPreference.priority).length;
    final excludedCount = _items.where((item) => item.preference == DealPreference.excluded).length;
    final storeNames = _storeNames;
    // Scoped to the current store filter, same as the store options below
    // are scoped to every store regardless of the current category filter -
    // each filter offers choices independent of the other one's selection.
    final availableCategories = _presentCategories(_storeFiltered);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Filters', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(
              '$priorityCount priority, $excludedCount excluded',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (storeNames.length > 1) ...[
              const SizedBox(height: 16),
              Text('Store', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _storeFilter == null,
                    onSelected: (_) {
                      setState(() => _storeFilter = null);
                      setModalState(() {});
                    },
                  ),
                  for (final name in storeNames)
                    ChoiceChip(
                      label: Text(name),
                      selected: _storeFilter == name,
                      onSelected: (_) {
                        setState(() => _storeFilter = name);
                        setModalState(() {});
                      },
                    ),
                ],
              ),
            ],
            if (availableCategories.length > 1) ...[
              const SizedBox(height: 16),
              Text('Category', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _categoryFilter == null,
                    onSelected: (_) {
                      setState(() => _categoryFilter = null);
                      setModalState(() {});
                    },
                  ),
                  for (final category in availableCategories)
                    ChoiceChip(
                      label: Text(category.label),
                      selected: _categoryFilter == category,
                      onSelected: (_) {
                        setState(() => _categoryFilter = category);
                        setModalState(() {});
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<DealItem> _coverFirst(List<DealItem> items) {
    final cover = items.where((item) => item.isCoverPage).toList();
    final rest = items.where((item) => !item.isCoverPage).toList();
    return [...cover, ...rest];
  }

  Widget _buildSectionHeader(DealCategory category) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        category.label,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildItemTile(DealItem item) {
    final priceText = item.priceText;
    final isPriority = item.preference == DealPreference.priority;
    final isExcluded = item.preference == DealPreference.excluded;
    final nameStyle = isExcluded ? const TextStyle(decoration: TextDecoration.lineThrough) : null;
    return Opacity(
      opacity: isExcluded ? 0.5 : 1,
      child: ListTile(
        onTap: () => _togglePreference(item),
        tileColor: isPriority ? Theme.of(context).colorScheme.primaryContainer : null,
        leading: isPriority ? Icon(Icons.star, color: Theme.of(context).colorScheme.primary) : null,
        title: Row(
          children: [
            Flexible(child: Text(item.name, style: nameStyle)),
            if (item.isCoverPage) ...[const SizedBox(width: 8), _buildCoverBadge()],
          ],
        ),
        subtitle: Text('${item.storeName} · page ${item.pageIndex}'),
        trailing: Text(priceText, style: TextStyle(fontWeight: FontWeight.bold, decoration: nameStyle?.decoration)),
      ),
    );
  }

  Widget _buildCoverBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.amber.shade700),
      ),
      child: Text(
        'COVER',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber.shade900),
      ),
    );
  }

  // The gate step reached from the deals view's "Preview meal plan" FAB (or
  // reopened via the preview app bar's "Edit meal plan structure" action):
  // lets the user validate/change what to plan - meal slots, portions,
  // dietary notes - before the AI call behind the actual preview runs.
  // Mirrors ConfigMealPlanScreen, but scoped to this flow's draft instead
  // of editing the saved config directly.
  Widget _buildStructureStep() {
    final draft = _structureDraft!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        Text(
          'What to plan',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Confirm or adjust the meal structure before the AI generates a preview.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                key: const ValueKey('structure-portions'),
                initialValue: '${draft.portionsPerMeal}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Portions per meal'),
                onChanged: _updateStructurePortions,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                key: const ValueKey('structure-diversity'),
                initialValue: '${draft.diversityWindowDays}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Diversity window (days)'),
                onChanged: _updateStructureDiversity,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('structure-dietary-notes'),
          initialValue: draft.dietaryNotes,
          maxLines: null,
          minLines: 2,
          decoration: const InputDecoration(
            labelText: 'Additional planning instructions',
            hintText: 'e.g. no more than 2 days of fish per week, no red meat',
          ),
          onChanged: _updateStructureDietaryNotes,
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                'Meal slots',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(icon: const Icon(Icons.add), tooltip: 'Add meal slot', onPressed: _addStructureSlot),
          ],
        ),
        for (var i = 0; i < draft.mealSlots.length; i++)
          _buildStructureSlotRow(i, draft.mealSlots[i], draft.mealSlots.length),
        const SizedBox(height: 8),
        Text('${draft.mealsPerWeek} meals / week', style: Theme.of(context).textTheme.bodySmall),
        // Bottom padding so the last row isn't hidden behind the pinned
        // "generate preview" bar.
        const SizedBox(height: 72),
      ],
    );
  }

  Widget _buildStructureSlotRow(int index, MealSlot slot, int slotCount) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<MealType>(
              key: ValueKey('structure-meal-type-${slot.id}'),
              initialValue: slot.mealType,
              decoration: const InputDecoration(labelText: 'Meal'),
              items: MealType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.name))).toList(),
              onChanged: (value) {
                if (value == null) return;
                _updateStructureSlot(index, slot.copyWith(mealType: value));
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              key: ValueKey('structure-protein-${slot.id}'),
              initialValue: slot.protein,
              decoration: const InputDecoration(labelText: 'Protein'),
              onChanged: (value) {
                final trimmed = value.trim();
                if (trimmed.isEmpty) return;
                _updateStructureSlot(index, slot.copyWith(protein: trimmed));
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              key: ValueKey('structure-count-${slot.id}'),
              initialValue: '${slot.count}',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Count'),
              onChanged: (value) {
                final parsed = int.tryParse(value);
                if (parsed == null || parsed < 0) return;
                _updateStructureSlot(index, slot.copyWith(count: parsed));
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove meal slot',
            onPressed: slotCount == 1 ? null : () => _removeStructureSlot(index),
          ),
        ],
      ),
    );
  }

  // Mirrors _buildGenerateFullPlanBar's placement/styling: pinned CTA for
  // the structure step, shown only while it's the step on screen.
  Widget _buildStructureBar() {
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: FilledButton.icon(
        onPressed: _isPreviewLoading ? null : _confirmStructureAndGeneratePreview,
        icon: _isPreviewLoading
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.arrow_forward),
        label: Text(_isPreviewLoading ? 'Generating…' : 'Looks good, generate preview'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }

  // A picker strip of one tile per meal, pinned above the detail card and
  // never hidden - unlike a stepper, every meal's name and status stays on
  // screen at all times, and switching which one is being edited is a
  // single tap on its tile rather than a forced Back/Next walk through the
  // others.
  Widget _buildReviewStep() {
    final preview = _preview!;
    final index = _reviewIndex;
    return Column(
      children: [
        _buildReviewPicker(preview.slots),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [_buildReviewCard(index, preview.slots[index], _slotRecipes[index])],
          ),
        ),
      ],
    );
  }

  Widget _buildReviewPicker(List<MealSlotPreview> slots) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          for (var i = 0; i < slots.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _buildReviewTile(i, slots[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewTile(int index, MealSlotPreview slot) {
    final isCurrent = index == _reviewIndex;
    final recipe = _slotRecipes[index];
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('review-step-$index'),
      onTap: () => _jumpToMeal(index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 124,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isCurrent ? colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isCurrent ? colorScheme.primary : Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  slot.mealType == MealType.lunch ? Icons.wb_sunny_outlined : Icons.nightlight_outlined,
                  size: 14,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _capitalize(slot.mealType.name),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (recipe != null) Icon(Icons.check_circle, size: 13, color: Colors.green.shade700),
              ],
            ),
            const SizedBox(height: 3),
            // The same three rows either way - what changes once a recipe
            // exists is where the names come from: the deal items already
            // anchoring the slot beforehand, the recipe's own confirmed
            // deal items after. Either way it's the bare ingredient (e.g.
            // "Broccoli"), never the recipe's own write-up of it (e.g.
            // "Steamed fresh broccoli florets"), so the strip stays
            // scannable at this size.
            if (recipe == null) ...[
              _buildReviewTileIngredient(Icons.set_meal_outlined, _anchorForCategory(slot, DealCategory.protein) ?? slot.protein),
              _buildReviewTileIngredient(Icons.grain, _anchorForCategory(slot, DealCategory.carbs) ?? '—'),
              _buildReviewTileIngredient(Icons.eco_outlined, _anchorForCategory(slot, DealCategory.vegetables) ?? '—'),
            ] else ...[
              _buildReviewTileIngredient(Icons.set_meal_outlined, _tileIngredientLabel(recipe.proteinComponent)),
              _buildReviewTileIngredient(Icons.grain, _tileIngredientLabel(recipe.carbComponent)),
              _buildReviewTileIngredient(Icons.eco_outlined, _tileIngredientLabel(recipe.vegetableComponent)),
            ],
          ],
        ),
      ),
    );
  }

  // The first of this slot's anchor items that's actually filed under
  // [category] in the fetched deals, if any - lets the tile guess at a
  // protein/carb/vegetable breakdown before a recipe (and its own
  // confirmed components) exists yet.
  String? _anchorForCategory(MealSlotPreview slot, DealCategory category) {
    for (final anchor in slot.anchorItems) {
      for (final item in _items) {
        if (item.category == category && _anchorNameKey(item.name) == _anchorNameKey(anchor.name)) {
          return anchor.name;
        }
      }
    }
    return null;
  }

  // The bare ingredient a component draws on (e.g. "Broccoli"), not the
  // recipe's own write-up of it (e.g. "Steamed fresh broccoli florets") -
  // the underlying deal item's name already is that bare ingredient, so
  // it's used whenever the component has one. Applies the same way to a
  // covered_by_protein component (e.g. buns baked into the pulled-pork
  // recipe) - the tile still names the actual ingredient rather than
  // pointing back at the protein line, even though the full card explains
  // it's covered there.
  String _tileIngredientLabel(MealComponent component) {
    if (component.dealItems.isNotEmpty) return component.dealItems.first.name;
    return component.name;
  }

  Widget _buildReviewTileIngredient(IconData icon, String name) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icon, size: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Expanded(
            child: Text(name, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewCard(int index, MealSlotPreview slot, MealSlotFull? recipe) {
    final isRegeneratingAnchors = _regeneratingSlots.contains(index);
    final isGeneratingRecipe = _generatingRecipeSlots.contains(index);
    final anchorsDisabled = isRegeneratingAnchors || isGeneratingRecipe;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  slot.mealType == MealType.lunch ? Icons.wb_sunny_outlined : Icons.nightlight_outlined,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_capitalize(slot.mealType.name)} · ${slot.protein}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text('${slot.totalPortionsNeeded} portions'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                IconButton(
                  icon: isRegeneratingAnchors
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 18),
                  tooltip: 'Regenerate suggested items',
                  visualDensity: VisualDensity.compact,
                  onPressed: anchorsDisabled ? null : () => _regenerateSlot(index),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${slot.count} meals × ${slot.portionsPerMeal} portions',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final anchor in slot.anchorItems) _buildAnchorChip(index, anchor, disabled: anchorsDisabled),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('Add item'),
                  visualDensity: VisualDensity.compact,
                  onPressed: anchorsDisabled ? null : () => _addAnchorItem(index),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(slot.note, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
            const Divider(height: 24),
            if (recipe != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Recipe',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: isGeneratingRecipe
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 18),
                    tooltip: 'Regenerate this recipe',
                    visualDensity: VisualDensity.compact,
                    onPressed: (isGeneratingRecipe || isRegeneratingAnchors) ? null : () => _generateSlotRecipe(index),
                  ),
                ],
              ),
              MealSlotFullCard(slot: recipe, onOpenRecipeLink: _openRecipeLink, showHeader: false),
            ] else if (isGeneratingRecipe)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(
                        _recipeGenerationPhaseLabel(_recipeGenerationPhase[index]),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              )
            else
              Text(
                'Anchors look good? Generate this meal\'s recipe below.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnchorChip(int slotIndex, AnchorItem anchor, {bool disabled = false}) {
    return InputChip(
      avatar: const Icon(Icons.swap_horiz, size: 16),
      label: Text('${anchor.name} · ${anchor.store}'),
      tooltip: 'Tap to swap, or use the × to remove',
      onPressed: disabled ? null : () => _swapAnchorItem(slotIndex, anchor),
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: disabled ? null : () => _removeAnchorItem(slotIndex, anchor),
    );
  }

  String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  // Mirrors the 'research'/'extraction' phase names MealPlanGenerationService
  // reports via onPhase (also used as-is for its own AI-call log entries) -
  // null means the phase callback hasn't fired yet (request still in
  // flight to the API).
  String _recipeGenerationPhaseLabel(String? phase) => switch (phase) {
    'research' => 'Searching for real recipe links…',
    'extraction' => 'Writing out the recipe…',
    _ => 'Generating…',
  };

  // The review step's single pinned CTA. There's no forced Back/Next
  // walk any more - the picker strip above already lets any meal be
  // reached in one tap - so this bar only ever has one job: generate the
  // meal currently on screen, or, once every meal has a recipe, save the
  // week. Anything in between (a meal is done, but others aren't yet)
  // needs no action here, so the bar disappears rather than showing a
  // disabled button.
  Widget _buildReviewBar() {
    final index = _reviewIndex;
    final hasRecipe = _slotRecipes[index] != null;
    final isGenerating = _generatingRecipeSlots.contains(index);
    final busy = _reviewBusy;

    final String label;
    final IconData icon;
    final VoidCallback? onPressed;
    if (!hasRecipe) {
      label = isGenerating ? 'Generating…' : 'Generate recipe';
      icon = Icons.auto_awesome;
      onPressed = busy ? null : () => _generateSlotRecipe(index);
    } else if (_allSlotsGenerated) {
      label = _isSavingWeek ? 'Saving…' : 'Save this week\'s plan';
      icon = Icons.save_outlined;
      onPressed = busy ? null : _saveWeekPlan;
    } else {
      return const SizedBox.shrink();
    }
    final showSpinner = isGenerating || _isSavingWeek;

    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: showSpinner
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }
}

class _AnchorPickerDialog extends StatelessWidget {
  const _AnchorPickerDialog({required this.items, this.title = 'Swap anchor item'});

  final List<DealItem> items;
  final String title;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        child: items.isEmpty
            ? const Padding(padding: EdgeInsets.all(8), child: Text('No available deal items.'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  return ListTile(
                    title: Text(item.name),
                    subtitle: Text('${item.storeName} · ${item.priceText}'),
                    onTap: () => Navigator.of(context).pop(item),
                  );
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}
