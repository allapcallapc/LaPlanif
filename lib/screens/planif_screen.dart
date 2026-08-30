import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/deal_item.dart';
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
import '../widgets/rate_limit_dialog.dart';
import 'planif_deals_screen.dart';
import 'planif_review_screen.dart';

/// Opens a recipe link. Injectable so tests can avoid driving a real
/// platform URL launcher.
typedef RecipeLinkLauncher = Future<void> Function(Uri uri);

/// Default [RecipeLinkLauncher]: hands the URL to the platform's own
/// browser/app handler.
Future<void> openRecipeLink(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

enum StoreFetchStatus { waiting, inProgress, done, failed }

class StoreFetchState {
  StoreFetchState(this.store);

  final StoreConfig store;
  StoreFetchStatus status = StoreFetchStatus.waiting;
  int itemCount = 0;
  String? errorMessage;
}

/// Bundles every service/repository Planif's screens are injected with, so
/// each of Deals/Structure/Review's constructors takes this one object
/// instead of repeating all eleven individual parameters - they're each a
/// real pushed screen now (see the flow-level doc comment on [PlanifScreen]
/// below), not a shared State's fields, so something has to carry the
/// dependencies from screen to screen.
class PlanifServices {
  PlanifServices({
    required this.repository,
    required this.scraperService,
    required this.extractionService,
    required this.aiConfigRepository,
    required this.preferenceRepository,
    required this.cacheRepository,
    required this.mealPlanConfigRepository,
    required this.mealHistoryRepository,
    required this.mealPlanDraftRepository,
    required this.previewService,
    required this.generationService,
    required this.rateLimitWait,
    required this.rateLimitPrompt,
    required this.launchRecipeLink,
  });

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
}

/// Planif's entry point and "home base". Fetching, browsing deals,
/// confirming what to plan, and reviewing the generated meal plan are each
/// their own screen ([PlanifDealsScreen], [PlanifStructureScreen],
/// [PlanifReviewScreen]) pushed with [Navigator.push] - a real back stack,
/// so the platform back button/gesture pops exactly one of them for free,
/// same as [HistoryDetailScreen] or [AiUsageScreen] elsewhere in this app.
///
/// This screen itself never shows deals or a meal plan. On open (and again
/// every time the flow is popped all the way back here) it decides between
/// three things to show: a plain "Fetch deals" prompt (nothing loaded yet),
/// a "Continue planning" card once something is - deal items, or a further
/// in-progress plan draft - paired with "Start a new plan" to discard it and
/// re-fetch, or the fetch-in-progress status rows while a fetch is running.
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
  final Duration rateLimitWait;
  final RateLimitPrompt rateLimitPrompt;
  final RecipeLinkLauncher launchRecipeLink;

  @override
  State<PlanifScreen> createState() => _PlanifScreenState();
}

class _PlanifScreenState extends State<PlanifScreen> {
  late final PlanifServices _services;
  List<StoreFetchState> _states = [];
  List<DealItem> _items = [];
  bool _isRunning = false;
  bool _hasRun = false;
  String? _apiKey;
  List<String> _models = [];
  List<String> _groundingModels = [];
  MealPlanDraft? _draft;
  // When _items was fetched (from cache or a live run) - null until either
  // has happened. Threaded through to Deals/Structure/Review so how old the
  // underlying deals are stays visible on every one of them (see issue #37).
  DateTime? _fetchedAt;

  @override
  void initState() {
    super.initState();
    _services = PlanifServices(
      repository: widget.repository,
      scraperService: widget.scraperService,
      extractionService: widget.extractionService,
      aiConfigRepository: widget.aiConfigRepository,
      preferenceRepository: widget.preferenceRepository,
      cacheRepository: widget.cacheRepository,
      mealPlanConfigRepository: widget.mealPlanConfigRepository,
      mealHistoryRepository: widget.mealHistoryRepository,
      mealPlanDraftRepository: widget.mealPlanDraftRepository,
      previewService: widget.previewService,
      generationService: widget.generationService,
      rateLimitWait: widget.rateLimitWait,
      rateLimitPrompt: widget.rateLimitPrompt,
      launchRecipeLink: widget.launchRecipeLink,
    );
    _loadCachedItems();
    _loadDraft();
  }

  // Restores whatever generated preview/recipes survived from before a
  // crash, refresh, or reclaimed tab (see issue #35) - saved incrementally
  // by PlanifReviewScreen after each successful generation step. Runs
  // independently of _loadCachedItems: the draft's own anchors/recipes
  // stand on their own regardless of whether the underlying deal cache also
  // loaded. Unlike the old single-screen flow, restoring a draft no longer
  // jumps straight into review on its own - it just makes "Continue
  // planning" available; the user still taps it to go there.
  Future<void> _loadDraft() async {
    final draft = await _services.mealPlanDraftRepository.load();
    if (!mounted) return;
    // A real fetch that started while this load was still in flight always
    // wins, same reasoning as _loadCachedItems.
    if (_isRunning) return;
    // Offering "Continue planning" into review re-enables actions
    // (regenerate, per-slot recipe generation) that need an API key -
    // _loadCachedItems only sets _apiKey as a side effect of a non-empty
    // deal cache, so load it directly here too. Otherwise a restored draft
    // with an empty deal cache would leave those actions silently doing
    // nothing instead of prompting to set a key, unlike every other entry
    // point that reaches them.
    final apiKey = _apiKey ?? await _services.aiConfigRepository.loadApiKey();
    final models = apiKey.isEmpty ? _models : await _services.aiConfigRepository.loadModels();
    final groundingModels = apiKey.isEmpty
        ? _groundingModels
        : await _services.aiConfigRepository.loadGroundingModels();
    if (!mounted) return;
    if (_isRunning) return;
    setState(() {
      _draft = draft;
      if (apiKey.isNotEmpty) {
        _apiKey = apiKey;
        _models = models;
        _groundingModels = groundingModels;
      }
    });
  }

  // Shows the last fetch's results immediately on open, so the user isn't
  // forced to re-fetch every time just to see deals they already pulled.
  Future<void> _loadCachedItems() async {
    final cached = await _services.cacheRepository.load();
    if (cached.isEmpty) return;
    final withPreferences = await _applyPreferences(cached);
    final fetchedAt = await _services.cacheRepository.loadFetchedAt();
    // Loaded alongside the cache so _hasRun implies _apiKey is set, same as
    // the _fetchAll path - otherwise "Continue planning" would render
    // enabled but silently do nothing once past deals until an actual fetch
    // runs.
    final apiKey = await _services.aiConfigRepository.loadApiKey();
    final models = apiKey.isEmpty ? <String>[] : await _services.aiConfigRepository.loadModels();
    final groundingModels = apiKey.isEmpty ? <String>[] : await _services.aiConfigRepository.loadGroundingModels();
    if (!mounted) return;
    // A real fetch that started (and possibly finished) while this cache
    // load was still in flight always wins - applying stale cached data on
    // top of it would silently discard fresher results.
    if (_isRunning || _hasRun) return;
    setState(() {
      _items = withPreferences;
      _fetchedAt = fetchedAt;
      _hasRun = true;
      if (apiKey.isNotEmpty) {
        _apiKey = apiKey;
        _models = models;
        _groundingModels = groundingModels;
      }
    });
  }

  // Re-runs both loaders once the user has popped all the way back here
  // from Deals/Structure/Review, so whatever changed while away - a
  // preference toggle, a freshly generated draft, a saved-and-cleared one -
  // is reflected in the continue/start-over choice instead of showing
  // whatever was true when that screen was first pushed.
  Future<void> _refresh() async {
    setState(() {
      _hasRun = false;
    });
    await _loadCachedItems();
    await _loadDraft();
  }

  Future<List<DealItem>> _applyPreferences(List<DealItem> items) async {
    final saved = await _services.preferenceRepository.loadAll();
    if (saved.isEmpty) return items;
    return items.map((item) {
      final preference = saved[item.preferenceKey];
      return preference == null ? item : item.copyWith(preference: preference);
    }).toList();
  }

  // Runs the fetch itself. Returns false (without touching any state beyond
  // the snackbar) when it never actually started because no API key is
  // configured - callers use that to decide whether there's anything fresh
  // to browse afterward.
  Future<bool> _fetchAll() async {
    final apiKey = await _services.aiConfigRepository.loadApiKey();
    if (apiKey.isEmpty) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return false;
    }

    final models = await _services.aiConfigRepository.loadModels();
    final groundingModels = await _services.aiConfigRepository.loadGroundingModels();
    final stores = await _services.repository.load();
    if (!mounted) return false;
    setState(() {
      _states = stores.map((s) => StoreFetchState(s)).toList();
      _items = [];
      _isRunning = true;
      _hasRun = false;
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
    // whatever was cached/selected (and its fetched-at time) before rather
    // than wiping it out for an empty result.
    var withPreferences = items;
    var fetchedAt = _fetchedAt;
    if (items.isNotEmpty) {
      // An explicit reload starts over: last fetch's priority/excluded
      // selections were made against items that are about to be replaced, so
      // keeping them around would silently misapply old choices to new
      // deals. Done only once there are actual new items to apply it to.
      await _services.preferenceRepository.clearAll();
      withPreferences = await _applyPreferences(items);
      fetchedAt = DateTime.now();
      try {
        await _services.cacheRepository.save(withPreferences);
      } catch (_) {
        // Non-fatal: the freshly fetched items are still shown for this
        // session, just not persisted for the next time the screen opens.
      }
    }
    if (!mounted) return true;
    setState(() {
      _items = withPreferences;
      _fetchedAt = fetchedAt;
      _isRunning = false;
      _hasRun = true;
    });
    return true;
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
      final pages = await _services.scraperService.fetchPages(state.store);
      for (var start = 0; start < pages.length; start += AiDealExtractionService.maxPagesPerCall) {
        final end = (start + AiDealExtractionService.maxPagesPerCall).clamp(0, pages.length);
        final chunk = pages.sublist(start, end);
        final controller = ModelFallbackController(models: remainingModels, waitBeforeRetry: _services.rateLimitWait);
        var usedModel = remainingModels.first;
        items.addAll(
          await controller.run(
            attempt: (model) {
              usedModel = model;
              return _services.extractionService.extractItems(
                apiKey: apiKey,
                storeName: state.store.name,
                pages: chunk,
                model: model,
              );
            },
            onRateLimited: ({required currentModel, nextModel}) {
              if (!mounted) return Future.value(RateLimitChoice.retrySame);
              return _services.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
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

  // "Fetch deals" (cold start) and "Start a new plan" (discarding whatever
  // is in progress) both do the same thing from here on: run the fetch,
  // then push the deals screen once there's something to show.
  Future<void> _fetchAndOpenDeals() async {
    final completed = await _fetchAll();
    if (!completed || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlanifDealsScreen(
          services: _services,
          items: _items,
          states: _states,
          apiKey: _apiKey,
          models: _models,
          groundingModels: _groundingModels,
          fetchedAt: _fetchedAt,
        ),
      ),
    );
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _startNewPlan() async {
    await _services.mealPlanDraftRepository.clear().catchError((_) {
      // Non-fatal - a failed clear just leaves the old draft resurfacing
      // alongside the fresh fetch below, no worse than not clearing at all.
    });
    if (!mounted) return;
    setState(() => _draft = null);
    await _fetchAndOpenDeals();
  }

  // "Continue planning": straight into review if a draft already exists (no
  // AI call needed - it's exactly what was there before), otherwise into
  // deals with whatever was already fetched/cached.
  Future<void> _continue() async {
    final draft = _draft;
    if (draft != null) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlanifReviewScreen(
            services: _services,
            items: _items,
            apiKey: _apiKey,
            models: _models,
            groundingModels: _groundingModels,
            config: draft.config,
            initialPreview: draft.preview,
            initialSlotRecipes: draft.slotRecipes,
            fetchedAt: _fetchedAt,
          ),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlanifDealsScreen(
            services: _services,
            items: _items,
            states: const [],
            apiKey: _apiKey,
            models: _models,
            groundingModels: _groundingModels,
            fetchedAt: _fetchedAt,
          ),
        ),
      );
    }
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Planif')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isRunning) return _buildFetchingProgress();
    if (_draft != null || _items.isNotEmpty) return _buildResumeOrStartOver();
    return _buildEmptyState();
  }

  Widget _buildFetchingProgress() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: _states.map(_buildStatusRow).toList()),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storefront_outlined, size: 40, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              const Text('Press "Fetch deals" to load flyer items.', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _fetchAndOpenDeals,
                icon: const Icon(Icons.refresh),
                label: const Text('Fetch deals'),
                style: FilledButton.styleFrom(minimumSize: const Size(220, 48)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Landing state once there's something to resume into - deal items, a
  // further in-progress draft, or both. "Continue planning" always leads to
  // the deepest thing there is to resume (review when a draft exists, deals
  // otherwise); "Start a new plan" discards it and re-fetches from scratch.
  Widget _buildResumeOrStartOver() {
    final draft = _draft;
    final total = draft?.slotRecipes.length ?? 0;
    final generated = draft?.slotRecipes.where((s) => s != null).length ?? 0;
    final subtitle = draft != null
        ? '$generated of $total meal${total == 1 ? '' : 's'} ready to review'
        : '${_items.length} deal item${_items.length == 1 ? '' : 's'} ready to plan';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'IN PROGRESS',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "This week's plan",
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _continue,
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Continue planning'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      'or',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _startNewPlan,
                icon: const Icon(Icons.refresh),
                label: const Text('Start a new plan'),
              ),
              const SizedBox(height: 6),
              Text(
                "Re-fetches this week's deals from scratch.",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
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
}
