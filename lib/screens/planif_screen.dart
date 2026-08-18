import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/store_config.dart';
import '../services/ai_config_repository.dart';
import '../services/ai_deal_extraction_service.dart';
import '../services/flyer_scraper_service.dart';
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
    Duration? rateLimitWait,
    RateLimitPrompt? rateLimitPrompt,
  }) : scraperService = scraperService ?? FlyerScraperService(),
       extractionService = extractionService ?? AiDealExtractionService(),
       aiConfigRepository = aiConfigRepository ?? AiConfigRepository(),
       rateLimitWait = rateLimitWait ?? const Duration(minutes: 1),
       rateLimitPrompt = rateLimitPrompt ?? showRateLimitDialog;

  final StoreConfigRepository repository;
  final FlyerScraperService scraperService;
  final AiDealExtractionService extractionService;
  final AiConfigRepository aiConfigRepository;

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

    if (!mounted) return;
    setState(() {
      _items = items;
      _isRunning = false;
      _hasRun = true;
    });
  }

  Future<void> _retryStore(StoreFetchState state) async {
    final apiKey = _apiKey;
    if (apiKey == null || _isRunning) return;

    setState(() => _isRunning = true);
    final items = await _fetchStore(state, apiKey, _models);
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
          Expanded(child: _buildResults()),
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
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(item.name)),
          if (item.isCoverPage) ...[const SizedBox(width: 8), _buildCoverBadge()],
        ],
      ),
      subtitle: Text('${item.storeName} · page ${item.pageIndex}'),
      trailing: Text(priceText, style: const TextStyle(fontWeight: FontWeight.bold)),
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
