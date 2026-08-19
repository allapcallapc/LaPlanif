import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/meal_plan_config.dart';
import '../models/meal_plan_preview.dart';
import '../models/store_config.dart';
import '../services/ai_config_repository.dart';
import '../services/ai_deal_extraction_service.dart';
import '../services/deal_preference_repository.dart';
import '../services/flyer_scraper_service.dart';
import '../services/meal_plan_config_repository.dart';
import '../services/meal_plan_preview_service.dart';
import '../services/model_fallback_controller.dart';
import '../services/store_config_repository.dart';
import '../utils/error_formatting.dart';
import '../widgets/rate_limit_dialog.dart';

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
    MealPlanConfigRepository? mealPlanConfigRepository,
    MealPlanPreviewService? previewService,
    Duration? rateLimitWait,
    RateLimitPrompt? rateLimitPrompt,
  }) : scraperService = scraperService ?? FlyerScraperService(),
       extractionService = extractionService ?? AiDealExtractionService(),
       aiConfigRepository = aiConfigRepository ?? AiConfigRepository(),
       preferenceRepository = preferenceRepository ?? DealPreferenceRepository(),
       mealPlanConfigRepository = mealPlanConfigRepository ?? MealPlanConfigRepository(),
       previewService = previewService ?? MealPlanPreviewService(),
       rateLimitWait = rateLimitWait ?? const Duration(minutes: 1),
       rateLimitPrompt = rateLimitPrompt ?? showRateLimitDialog;

  final StoreConfigRepository repository;
  final FlyerScraperService scraperService;
  final AiDealExtractionService extractionService;
  final AiConfigRepository aiConfigRepository;
  final DealPreferenceRepository preferenceRepository;
  final MealPlanConfigRepository mealPlanConfigRepository;
  final MealPlanPreviewService previewService;

  /// How long [ModelFallbackController] waits before its one automatic
  /// retry on a rate-limited call. Injectable so tests don't have to wait.
  final Duration rateLimitWait;

  /// Asks what to do when a call is still rate limited after that retry.
  /// Injectable so tests can avoid driving a real dialog.
  final RateLimitPrompt rateLimitPrompt;

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
  MealPlanPreview? _preview;
  MealPlanConfig? _mealPlanConfig;
  bool _isPreviewLoading = false;
  bool _showPreview = false;
  final Set<int> _regeneratingSlots = {};

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
    });

    // Fetched one store at a time, not in parallel: every store hits the
    // same AI API key, and firing them all at once was tripping Gemini's
    // rate limit (HTTP 429) far more often than fetching sequentially does.
    final items = <DealItem>[];
    for (final state in _states) {
      items.addAll(await _fetchStore(state, apiKey, models));
    }

    final withPreferences = await _applyPreferences(items);
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
    final apiKey = _apiKey;
    if (apiKey == null || _isPreviewLoading || _regeneratingSlots.isNotEmpty) return;

    final config = await widget.mealPlanConfigRepository.load();
    setState(() {
      _isPreviewLoading = true;
      _mealPlanConfig = config;
    });

    final controller = ModelFallbackController(models: _models, waitBeforeRetry: widget.rateLimitWait);
    try {
      final preview = await controller.run(
        attempt: (model) => widget.previewService.previewMealPlan(
          apiKey: apiKey,
          mealSlots: config.mealSlots,
          portionsPerMeal: config.portionsPerMeal,
          items: _items,
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
        _isPreviewLoading = false;
        _showPreview = true;
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _regeneratingSlots.remove(index));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not regenerate this recipe: ${stripExceptionPrefix(e)}')));
    }
  }

  // Every anchor item currently used anywhere in the preview, across every
  // slot - an ingredient shouldn't anchor more than one slot, so neither the
  // swap nor the add picker should offer one already spoken for elsewhere.
  Set<String> _usedAnchorKeys() => {
    for (final slot in _preview!.slots)
      for (final anchor in slot.anchorItems) '${anchor.name}::${anchor.store}',
  };

  Future<void> _swapAnchorItem(int slotIndex, AnchorItem current) async {
    final usedKeys = _usedAnchorKeys();
    final available = _items
        .where((item) => item.preference != DealPreference.excluded)
        .where((item) => !usedKeys.contains('${item.name}::${item.storeName}'))
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
    });
  }

  Future<void> _addAnchorItem(int slotIndex) async {
    final usedKeys = _usedAnchorKeys();
    final available = _items
        .where((item) => item.preference != DealPreference.excluded)
        .where((item) => !usedKeys.contains('${item.name}::${item.storeName}'))
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
    });
  }

  void _removeAnchorItem(int slotIndex, AnchorItem anchor) {
    setState(() {
      final slots = [..._preview!.slots];
      final slot = slots[slotIndex];
      final anchors = slot.anchorItems.where((a) => !identical(a, anchor)).toList();
      slots[slotIndex] = slot.copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
    });
  }

  void _onGenerateFullPlan() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Full recipe generation is coming soon.')));
  }

  Future<void> _retryStore(StoreFetchState state) async {
    final apiKey = _apiKey;
    if (apiKey == null || _isRunning) return;

    setState(() => _isRunning = true);
    final rawItems = await _fetchStore(state, apiKey, _models);
    final items = await _applyPreferences(rawItems);
    if (!mounted) return;
    setState(() {
      _items = [..._items.where((item) => item.storeName != state.store.name), ...items];
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
    return Scaffold(
      appBar: AppBar(title: const Text('Planif')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                Text('Step 1', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _isRunning ? null : _fetchAll,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(_isRunning ? 'Fetching…' : 'Fetch deals'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
          if (_states.isNotEmpty) ...[
            const Divider(height: 1),
            if (_hasRun) _buildStatusSummary() else ..._states.map(_buildStatusRow),
            const Divider(height: 1),
          ],
          if (_hasRun && _items.isNotEmpty) ...[_buildStep2Row(), const Divider(height: 1)],
          Expanded(child: _showPreview && _preview != null ? _buildPreviewList() : _buildResults()),
        ],
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

    // filtered can't be empty here: _storeFilter is only ever set to a name
    // drawn from storeNames, which is itself derived from _items, so at
    // least one item always matches.
    return Column(
      children: [
        _buildPreferenceSummary(),
        if (storeNames.length > 1) _buildStoreFilterRow(storeNames),
        Expanded(
          child: ListView(
            children: [
              for (final category in _sectionOrder)
                if ((grouped[category] ?? const []).isNotEmpty) ...[
                  _buildSectionHeader(category.label),
                  ..._coverFirst(grouped[category]!).map(_buildItemTile),
                ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreferenceSummary() {
    final priorityCount = _items.where((item) => item.preference == DealPreference.priority).length;
    final excludedCount = _items.where((item) => item.preference == DealPreference.excluded).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '$priorityCount priority, $excludedCount excluded',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildStoreFilterRow(List<String> storeNames) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: _storeFilter == null,
              onSelected: (_) => setState(() => _storeFilter = null),
            ),
            for (final name in storeNames) ...[
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text(name),
                selected: _storeFilter == name,
                onSelected: (_) => setState(() => _storeFilter = name),
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

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildItemTile(DealItem item) {
    final priceText = item.unit.isEmpty ? item.price : '${item.price}/${item.unit}';
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

  Widget _buildStep2Row() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Text('Step 2', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              FilledButton.icon(
                onPressed: (_isPreviewLoading || _regeneratingSlots.isNotEmpty) ? null : _generatePreview,
                icon: _isPreviewLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.restaurant_menu, size: 18),
                label: Text(
                  _isPreviewLoading
                      ? 'Generating…'
                      : (_preview == null ? 'Preview meal plan' : 'Regenerate preview'),
                ),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
              ),
            ],
          ),
        ),
        if (_preview != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              // Wrap instead of a Row: at narrow widths both chips together
              // can outgrow the line, and Wrap drops the second one to a new
              // line instead of overflowing or needing a scroll gesture to
              // reach it.
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Deal items'),
                    selected: !_showPreview,
                    onSelected: (_) => setState(() => _showPreview = false),
                  ),
                  ChoiceChip(
                    label: const Text('Meal plan preview'),
                    selected: _showPreview,
                    onSelected: (_) => setState(() => _showPreview = true),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPreviewList() {
    final preview = _preview!;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: preview.slots.length + 1,
      itemBuilder: (context, i) {
        if (i == preview.slots.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FilledButton.icon(
              onPressed: _onGenerateFullPlan,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Looks good, generate full plan →'),
            ),
          );
        }
        return _buildPreviewCard(i, preview.slots[i]);
      },
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
                for (final anchor in slot.anchorItems) _buildAnchorChip(index, anchor),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('Add item'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _addAnchorItem(index),
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

  Widget _buildAnchorChip(int slotIndex, AnchorItem anchor) {
    return InputChip(
      avatar: const Icon(Icons.swap_horiz, size: 16),
      label: Text('${anchor.name} · ${anchor.store}'),
      tooltip: 'Tap to swap, or use the × to remove',
      onPressed: () => _swapAnchorItem(slotIndex, anchor),
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: () => _removeAnchorItem(slotIndex, anchor),
    );
  }

  String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
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
                  final priceText = item.unit.isEmpty ? item.price : '${item.price}/${item.unit}';
                  return ListTile(
                    title: Text(item.name),
                    subtitle: Text('${item.storeName} · $priceText'),
                    onTap: () => Navigator.of(context).pop(item),
                  );
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}
