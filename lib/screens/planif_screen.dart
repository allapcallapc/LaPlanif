import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/deal_item.dart';
import '../models/meal_plan_config.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';
import '../models/store_config.dart';
import '../services/ai_config_repository.dart';
import '../services/ai_deal_extraction_service.dart';
import '../services/deal_cache_repository.dart';
import '../services/deal_preference_repository.dart';
import '../services/flyer_scraper_service.dart';
import '../services/meal_plan_config_repository.dart';
import '../services/meal_plan_generation_service.dart';
import '../services/meal_plan_preview_service.dart';
import '../services/model_fallback_controller.dart';
import '../services/store_config_repository.dart';
import '../utils/error_formatting.dart';
import '../widgets/rate_limit_dialog.dart';

/// Which of Step 2's results the screen is currently showing.
enum _ViewMode { deals, preview, full }

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
       previewService = previewService ?? MealPlanPreviewService(),
       generationService = generationService ?? MealPlanGenerationService(),
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
  String? _apiKey;
  List<String> _models = [];
  List<String> _groundingModels = [];
  MealPlanPreview? _preview;
  MealPlanConfig? _mealPlanConfig;
  bool _isPreviewLoading = false;
  _ViewMode _viewMode = _ViewMode.deals;
  final Set<int> _regeneratingSlots = {};
  MealPlanFull? _fullPlan;
  bool _isGeneratingFullPlan = false;

  // One stable key per category, so a quick-jump chip can scroll the deals
  // list to that section's header regardless of how many/which categories
  // are actually present in a given fetch.
  final Map<DealCategory, GlobalKey> _sectionKeys = {
    for (final category in DealCategory.values) category: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    _loadCachedItems();
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

  Future<void> _generatePreview() async {
    if (_isPreviewLoading || _regeneratingSlots.isNotEmpty) return;
    final apiKey = _apiKey;
    if (apiKey == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }

    final config = await widget.mealPlanConfigRepository.load();
    setState(() => _isPreviewLoading = true);

    final controller = ModelFallbackController(models: _models, waitBeforeRetry: widget.rateLimitWait);
    try {
      final preview = await controller.run(
        attempt: (model) => widget.previewService.previewMealPlan(
          apiKey: apiKey,
          mealSlots: config.mealSlots,
          portionsPerMeal: config.portionsPerMeal,
          items: _items,
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
        _preview = preview;
        _mealPlanConfig = config;
        _isPreviewLoading = false;
        _viewMode = _ViewMode.preview;
        // A freshly regenerated preview can have entirely different anchors,
        // so any previously generated full plan (recipes built on the old
        // anchors) is stale - drop it rather than leave a mismatched result
        // reachable from the view switcher.
        _fullPlan = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPreviewLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not generate preview: ${stripExceptionPrefix(e)}')));
    }
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

    final controller = ModelFallbackController(models: _models, waitBeforeRetry: widget.rateLimitWait);
    try {
      final result = await controller.run(
        attempt: (model) => widget.previewService.previewMealPlan(
          apiKey: apiKey,
          mealSlots: [config.mealSlots[index]],
          portionsPerMeal: config.portionsPerMeal,
          items: _items,
          alreadyUsedAnchors: alreadyUsedAnchors,
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
        _fullPlan = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _regeneratingSlots.remove(index));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not regenerate this recipe: ${stripExceptionPrefix(e)}')));
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
      _fullPlan = null;
    });
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
      _fullPlan = null;
    });
  }

  void _removeAnchorItem(int slotIndex, AnchorItem anchor) {
    setState(() {
      final slots = [..._preview!.slots];
      final slot = slots[slotIndex];
      final anchors = slot.anchorItems.where((a) => !identical(a, anchor)).toList();
      slots[slotIndex] = slot.copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _fullPlan = null;
    });
  }

  Future<void> _generateFullPlan() async {
    final apiKey = _apiKey;
    final preview = _preview;
    if (apiKey == null || preview == null || _isGeneratingFullPlan || _isPreviewLoading || _regeneratingSlots.isNotEmpty) {
      return;
    }

    setState(() => _isGeneratingFullPlan = true);

    final dietaryNotes = _mealPlanConfig?.dietaryNotes ?? '';
    final controller = ModelFallbackController(models: _models, waitBeforeRetry: widget.rateLimitWait);
    try {
      final fullPlan = await controller.run(
        attempt: (model) => widget.generationService.generateMealPlan(
          apiKey: apiKey,
          slots: preview.slots,
          items: _items,
          dietaryNotes: dietaryNotes,
          model: model,
          groundingModels: _groundingModels,
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() {
        _fullPlan = fullPlan;
        _isGeneratingFullPlan = false;
        _viewMode = _ViewMode.full;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isGeneratingFullPlan = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not generate full meal plan: ${stripExceptionPrefix(e)}')));
    }
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
      // A retry can drop the filtered store to zero items, which would
      // otherwise leave _storeFilter pointing at a name _buildResults can no
      // longer find - reset it rather than showing an unexplained empty list.
      if (_storeFilter != null && !_items.any((item) => item.storeName == _storeFilter)) {
        _storeFilter = null;
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
    // The full-plan CTA lives in a persistent footer instead of at the
    // bottom of the preview list - it stays reachable without scrolling and
    // sits far enough from the (deliberately smaller/outlined) "Regenerate
    // preview" button up top that the two are no longer easy to mix up.
    final showGenerateFullPlanBar = _viewMode == _ViewMode.preview && _preview != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Planif'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: FilledButton.icon(
                onPressed: _isRunning ? null : _fetchAll,
                icon: _isRunning
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, size: 18),
                label: Text(_isRunning ? 'Fetching…' : 'Fetch deals'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_states.isNotEmpty) ...[
            if (_hasRun) _buildStatusSummary() else ..._states.map(_buildStatusRow),
            const Divider(height: 1),
          ],
          if (_hasRun && _items.isNotEmpty) ...[_buildStep2Bar(), const Divider(height: 1)],
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: showGenerateFullPlanBar ? _buildGenerateFullPlanBar() : null,
    );
  }

  Widget _buildBody() {
    if (_viewMode == _ViewMode.preview && _preview != null) return _buildPreviewList();
    if (_viewMode == _ViewMode.full && _fullPlan != null) return _buildFullPlanList();
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
        const Icon(Icons.check_circle, color: Colors.green),
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
      return Chip(
        avatar: const Icon(Icons.check_circle, size: 16, color: Colors.green),
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

    final storeNames = _items.map((item) => item.storeName).toSet().toList()..sort();
    final filtered = _storeFilter == null
        ? _items
        : _items.where((item) => item.storeName == _storeFilter).toList();

    final grouped = <DealCategory, List<DealItem>>{};
    for (final item in filtered) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }

    final presentCategories = [
      for (final category in _sectionOrder)
        if ((grouped[category] ?? const []).isNotEmpty) category,
    ];

    // filtered can't be empty here: _storeFilter is only ever set to a name
    // drawn from storeNames, which is itself derived from _items, so at
    // least one item always matches.
    return Column(
      children: [
        _buildFilterBar(storeNames),
        if (presentCategories.length > 1) _buildCategoryJumpRow(presentCategories),
        Expanded(
          child: ListView(
            // A generous cacheExtent keeps every section built up front (not
            // just what's near the viewport) - otherwise a category jump chip
            // for a section far below the fold would find no context to
            // scroll to, since Flutter's default sliver caching only builds
            // children close to what's currently visible.
            cacheExtent: 10000,
            children: [
              for (final category in presentCategories) ...[
                _buildSectionHeader(category),
                ..._coverFirst(grouped[category]!).map(_buildItemTile),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Preference summary and store filter share one compact row instead of
  // two stacked ones, so switching stores/categories doesn't cost as much
  // vertical space before the actual deal list starts.
  Widget _buildFilterBar(List<String> storeNames) {
    final priorityCount = _items.where((item) => item.preference == DealPreference.priority).length;
    final excludedCount = _items.where((item) => item.preference == DealPreference.excluded).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          Text(
            '$priorityCount priority, $excludedCount excluded',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (storeNames.length > 1) ...[
            ChoiceChip(
              label: const Text('All'),
              selected: _storeFilter == null,
              onSelected: (_) => setState(() => _storeFilter = null),
            ),
            for (final name in storeNames)
              ChoiceChip(
                label: Text(name),
                selected: _storeFilter == name,
                onSelected: (_) => setState(() => _storeFilter = name),
              ),
          ],
        ],
      ),
    );
  }

  // A row of icon-only chips (no category label text - the section headers
  // already own that text, and duplicating it would just be more clutter)
  // that jump the deals list straight to a category, so finding e.g. carbs
  // doesn't mean scrolling past everything ahead of it.
  Widget _buildCategoryJumpRow(List<DealCategory> categories) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final category in categories) ...[
              Tooltip(
                message: category.label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _scrollToSection(category),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(_categoryIcon(category), size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  IconData _categoryIcon(DealCategory category) => switch (category) {
    DealCategory.protein => Icons.set_meal_outlined,
    DealCategory.vegetables => Icons.eco_outlined,
    DealCategory.carbs => Icons.bakery_dining_outlined,
    DealCategory.uncategorized => Icons.category_outlined,
  };

  void _scrollToSection(DealCategory category) {
    final sectionContext = _sectionKeys[category]?.currentContext;
    if (sectionContext == null) return;
    Scrollable.ensureVisible(sectionContext, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  List<DealItem> _coverFirst(List<DealItem> items) {
    final cover = items.where((item) => item.isCoverPage).toList();
    final rest = items.where((item) => !item.isCoverPage).toList();
    return [...cover, ...rest];
  }

  Widget _buildSectionHeader(DealCategory category) {
    return Padding(
      key: _sectionKeys[category],
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

  // View-mode chips and the preview/regenerate action share one compact row.
  // The regenerate action is deliberately a small outlined button here -
  // not a big filled pill like "Fetch deals" or the full-plan CTA - so it
  // reads as a secondary action and isn't easy to mistake for the primary
  // "generate full plan" button in the footer.
  Widget _buildStep2Bar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _preview == null
                ? const SizedBox.shrink()
                // Wrap instead of a Row: at narrow widths the chips together
                // can outgrow the line, and Wrap drops the overflow to a new
                // line instead of overflowing or needing a scroll gesture.
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Deal items'),
                        selected: _viewMode == _ViewMode.deals,
                        onSelected: (_) => setState(() => _viewMode = _ViewMode.deals),
                      ),
                      ChoiceChip(
                        label: const Text('Meal plan preview'),
                        selected: _viewMode == _ViewMode.preview,
                        onSelected: (_) => setState(() => _viewMode = _ViewMode.preview),
                      ),
                      if (_fullPlan != null)
                        ChoiceChip(
                          label: const Text('Full meal plan'),
                          selected: _viewMode == _ViewMode.full,
                          onSelected: (_) => setState(() => _viewMode = _ViewMode.full),
                        ),
                    ],
                  ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: (_isPreviewLoading || _regeneratingSlots.isNotEmpty) ? null : _generatePreview,
            icon: _isPreviewLoading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.restaurant_menu, size: 16),
            label: Text(
              _isPreviewLoading ? 'Generating…' : (_preview == null ? 'Preview meal plan' : 'Regenerate preview'),
              style: const TextStyle(fontSize: 13),
            ),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewList() {
    final preview = _preview!;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: preview.slots.length,
      itemBuilder: (context, i) => _buildPreviewCard(i, preview.slots[i]),
    );
  }

  // The primary CTA for the preview step: pinned to the bottom of the
  // screen (not the end of a scrollable list) so it's always reachable
  // without scrolling, and visually far from the small "Regenerate preview"
  // button up top so the two don't get tapped by mistake for each other.
  Widget _buildGenerateFullPlanBar() {
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: FilledButton.icon(
        onPressed: (_isGeneratingFullPlan || _isPreviewLoading || _regeneratingSlots.isNotEmpty)
            ? null
            : _generateFullPlan,
        icon: _isGeneratingFullPlan
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.arrow_forward),
        label: Text(_isGeneratingFullPlan ? 'Generating full recipes…' : 'Looks good, generate full plan →'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }

  Widget _buildPreviewCard(int index, MealSlotPreview slot) {
    final isRegenerating = _regeneratingSlots.contains(index);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
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
                  icon: isRegenerating
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 18),
                  tooltip: 'Regenerate this recipe',
                  visualDensity: VisualDensity.compact,
                  onPressed: (_isPreviewLoading || isRegenerating) ? null : () => _regenerateSlot(index),
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
                for (final anchor in slot.anchorItems) _buildAnchorChip(index, anchor, disabled: isRegenerating),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('Add item'),
                  visualDensity: VisualDensity.compact,
                  onPressed: isRegenerating ? null : () => _addAnchorItem(index),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(slot.note, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
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

  Widget _buildFullPlanList() {
    final plan = _fullPlan!;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: plan.slots.length,
      itemBuilder: (context, i) => _buildFullPlanCard(plan.slots[i]),
    );
  }

  Widget _buildFullPlanCard(MealSlotFull slot) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
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
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${slot.count} meals × ${slot.portionsPerMeal} portions',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 20),
            _buildComponentBlock('Protein', slot.proteinComponent),
            const Divider(height: 20),
            _buildComponentBlock('Carb', slot.carbComponent, coveredNoun: 'carb'),
            const Divider(height: 20),
            _buildComponentBlock('Vegetable', slot.vegetableComponent, coveredNoun: 'vegetable'),
          ],
        ),
      ),
    );
  }

  // covered_by_protein components are merged into the protein section
  // instead of getting their own redundant sub-section - there's nothing
  // else to show for them beyond a pointer back up to the protein recipe.
  Widget _buildComponentBlock(String label, MealComponent component, {String? coveredNoun}) {
    if (component.type == MealComponentType.coveredByProtein) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.merge_type, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'This recipe already includes the ${coveredNoun ?? label.toLowerCase()} — see above.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      );
    }
    return _buildComponentSection(label, component);
  }

  Widget _buildComponentSection(String label, MealComponent component) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            _buildTypeChip(component.type),
            if (component.usesWeeklyDeal) _buildDealBadge(),
          ],
        ),
        const SizedBox(height: 4),
        Text(component.name, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        if (component.recipeUrl != null) _buildRecipeLink(component.recipeUrl!),
        if (component.type == MealComponentType.simpleSide && component.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(component.note, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (component.type == MealComponentType.aiRecipe) ...[
          if (component.ingredients.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Ingredients', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
            for (final ingredient in component.ingredients)
              Text('• ${ingredient.name} — ${ingredient.amount}', style: Theme.of(context).textTheme.bodySmall),
          ],
          if (component.instructions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Steps', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
            for (final entry in component.instructions.asMap().entries)
              Text('${entry.key + 1}. ${entry.value}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
        if (component.usesWeeklyDeal && component.dealItems.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: component.dealItems.map(_buildDealItemChip).toList(),
          ),
        ],
      ],
    );
  }

  // Only ever called for link/aiRecipe/simpleSide: _buildComponentBlock
  // intercepts coveredByProtein before delegating here, so that case isn't
  // handled - a fourth chip label for it would be dead code.
  Widget _buildTypeChip(MealComponentType type) {
    final (label, icon) = type == MealComponentType.link
        ? ('Recipe link', Icons.link)
        : type == MealComponentType.aiRecipe
        ? ('AI recipe', Icons.auto_awesome)
        : ('Simple side', Icons.eco_outlined);
    return Chip(
      avatar: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildDealBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.shade100,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.green.shade700),
      ),
      child: Text(
        "This week's deal",
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green.shade900),
      ),
    );
  }

  Widget _buildDealItemChip(AnchorItem item) {
    return Chip(
      avatar: const Icon(Icons.local_offer_outlined, size: 14),
      label: Text('${item.name} · ${item.store}', style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildRecipeLink(String url) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: () => _openRecipeLink(url),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.open_in_new, size: 14, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                url,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
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
