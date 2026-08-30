import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../services/ai_deal_extraction_service.dart';
import '../services/model_fallback_controller.dart';
import '../utils/error_formatting.dart';
import '../widgets/meal_plan_started_bar.dart';
import 'planif_screen.dart';
import 'planif_structure_screen.dart';

const _sectionOrder = [DealCategory.protein, DealCategory.vegetables, DealCategory.carbs, DealCategory.uncategorized];

/// Browses what a fetch (or the cache) produced: filterable by store and
/// category, with a priority/excluded preference on every item and a retry
/// action for any store that failed. The "Preview meal plan" FAB is the only
/// way forward from here, pushing [PlanifStructureScreen] - reached either
/// fresh from [PlanifScreen] or via "Continue planning" there.
class PlanifDealsScreen extends StatefulWidget {
  const PlanifDealsScreen({
    super.key,
    required this.services,
    required this.items,
    required this.states,
    required this.apiKey,
    required this.models,
    required this.groundingModels,
    required this.fetchedAt,
  });

  final PlanifServices services;
  final List<DealItem> items;
  final List<StoreFetchState> states;
  final String? apiKey;
  final List<String> models;
  final List<String> groundingModels;
  final DateTime? fetchedAt;

  @override
  State<PlanifDealsScreen> createState() => _PlanifDealsScreenState();
}

class _PlanifDealsScreenState extends State<PlanifDealsScreen> {
  late List<DealItem> _items;
  late List<StoreFetchState> _states;
  String? _storeFilter;
  DealCategory? _categoryFilter;
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    _items = widget.items;
    _states = widget.states;
  }

  Future<void> _togglePreference(DealItem item) async {
    final next = item.preference.next;
    final updated = item.copyWith(preference: next);
    setState(() {
      final index = _items.indexOf(item);
      if (index != -1) _items[index] = updated;
    });
    await widget.services.preferenceRepository.setPreference(item.preferenceKey, next);
  }

  Future<List<DealItem>> _applyPreferences(List<DealItem> items) async {
    final saved = await widget.services.preferenceRepository.loadAll();
    if (saved.isEmpty) return items;
    return items.map((item) {
      final preference = saved[item.preferenceKey];
      return preference == null ? item : item.copyWith(preference: preference);
    }).toList();
  }

  Future<void> _retryStore(StoreFetchState state) async {
    final apiKey = widget.apiKey;
    if (apiKey == null || _isRunning) return;

    setState(() => _isRunning = true);
    final rawItems = await _fetchStore(state, apiKey, widget.models);
    final items = await _applyPreferences(rawItems);
    final merged = [..._items.where((item) => item.storeName != state.store.name), ...items];
    try {
      await widget.services.cacheRepository.save(merged);
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
    var remainingModels = models;
    try {
      final pages = await widget.services.scraperService.fetchPages(state.store);
      for (var start = 0; start < pages.length; start += AiDealExtractionService.maxPagesPerCall) {
        final end = (start + AiDealExtractionService.maxPagesPerCall).clamp(0, pages.length);
        final chunk = pages.sublist(start, end);
        final controller = ModelFallbackController(
          models: remainingModels,
          waitBeforeRetry: widget.services.rateLimitWait,
        );
        var usedModel = remainingModels.first;
        items.addAll(
          await controller.run(
            attempt: (model) {
              usedModel = model;
              return widget.services.extractionService.extractItems(
                apiKey: apiKey,
                storeName: state.store.name,
                pages: chunk,
                model: model,
              );
            },
            onRateLimited: ({required currentModel, nextModel}) {
              if (!mounted) return Future.value(RateLimitChoice.retrySame);
              return widget.services.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
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

  // The only forward action from here. Checks for an API key up front since
  // nothing past this point (structure, then the preview call it leads to)
  // can proceed without one either.
  Future<void> _openStructure() async {
    final apiKey = widget.apiKey;
    if (apiKey == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }
    final config = await widget.services.mealPlanConfigRepository.load();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlanifStructureScreen(
          services: widget.services,
          items: _items,
          apiKey: apiKey,
          models: widget.models,
          groundingModels: widget.groundingModels,
          initialConfig: config,
          fetchedAt: widget.fetchedAt,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showFab = _items.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Deals'),
        actions: [
          if (_items.isNotEmpty) _buildPreferenceSummary(),
          if (_items.isNotEmpty) _buildFilterButton(),
          const SizedBox(width: 4),
        ],
        bottom: mealPlanStartedBar(context, widget.fetchedAt),
      ),
      body: Column(
        children: [
          if (_states.isNotEmpty) ...[_buildStatusSummary(), const Divider(height: 1)],
          Expanded(child: _buildResults()),
        ],
      ),
      floatingActionButton: showFab ? _buildPreviewFab() : null,
    );
  }

  Widget _buildPreferenceSummary() {
    final priorityCount = _items.where((item) => item.preference == DealPreference.priority).length;
    final excludedCount = _items.where((item) => item.preference == DealPreference.excluded).length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: Text(
          '$priorityCount priority, $excludedCount excluded',
          style: Theme.of(context).textTheme.labelMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

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

  Widget _buildPreviewFab() {
    return FloatingActionButton.extended(
      onPressed: _openStructure,
      icon: const Icon(Icons.restaurant_menu),
      label: const Text('Preview meal plan'),
    );
  }

  Widget _buildStatusSummary() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(spacing: 8, runSpacing: 4, children: _states.map(_buildStatusChip).toList()),
    );
  }

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
    if (_items.isEmpty) {
      return const Center(child: Text('No items found.'));
    }

    final filtered = _filteredItems;
    if (filtered.isEmpty) {
      return const Center(child: Text('No items match the current filters.'));
    }

    final grouped = <DealCategory, List<DealItem>>{};
    for (final item in filtered) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    final presentCategories = _presentCategories(filtered);

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

  void _openFilterSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) =>
          StatefulBuilder(builder: (context, setModalState) => _buildFilterSheetContent(setModalState)),
    );
  }

  Widget _buildFilterSheetContent(StateSetter setModalState) {
    final priorityCount = _items.where((item) => item.preference == DealPreference.priority).length;
    final excludedCount = _items.where((item) => item.preference == DealPreference.excluded).length;
    final storeNames = _storeNames;
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
        trailing: Text(
          priceText,
          style: TextStyle(fontWeight: FontWeight.bold, decoration: nameStyle?.decoration),
        ),
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
}
