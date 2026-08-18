import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/store_config.dart';
import '../services/flyer_scraper_service.dart';
import '../services/item_categorizer.dart';
import '../services/store_config_repository.dart';

const _sectionOrder = [
  DealCategory.protein,
  DealCategory.vegetables,
  DealCategory.carbs,
  DealCategory.uncategorized,
];

String _sectionLabel(DealCategory category) => switch (category) {
  DealCategory.protein => 'Protein',
  DealCategory.vegetables => 'Vegetables',
  DealCategory.carbs => 'Carbs',
  DealCategory.uncategorized => 'Uncategorized',
};

enum StoreFetchStatus { waiting, inProgress, done, failed }

class StoreFetchState {
  StoreFetchState(this.store);

  final StoreConfig store;
  StoreFetchStatus status = StoreFetchStatus.waiting;
  int itemCount = 0;
  String? errorMessage;
}

class PlanifScreen extends StatefulWidget {
  PlanifScreen({super.key, required this.repository, FlyerScraperService? scraper})
    : scraper = scraper ?? FlyerScraperService();

  final StoreConfigRepository repository;
  final FlyerScraperService scraper;

  @override
  State<PlanifScreen> createState() => _PlanifScreenState();
}

class _PlanifScreenState extends State<PlanifScreen> {
  List<StoreFetchState> _states = [];
  List<DealItem> _items = [];
  bool _isRunning = false;
  bool _hasRun = false;
  String? _storeFilter;

  Future<void> _fetchAll() async {
    final stores = await widget.repository.load();
    if (!mounted) return;
    setState(() {
      _states = stores.map((s) => StoreFetchState(s)).toList();
      _items = [];
      _isRunning = true;
      _hasRun = false;
      _storeFilter = null;
    });

    final results = await Future.wait(_states.map(_fetchStore));

    if (!mounted) return;
    setState(() {
      _items = results.expand((items) => items).toList();
      _isRunning = false;
      _hasRun = true;
    });
  }

  Future<List<DealItem>> _fetchStore(StoreFetchState state) async {
    setState(() => state.status = StoreFetchStatus.inProgress);
    try {
      final items = await widget.scraper.fetchDeals(state.store);
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
        });
      }
      return const [];
    }
  }

  String _shortReason(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
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

  // Future.wait starts every _fetchStore call synchronously before any of
  // them can yield back to the UI thread, so every store's status has
  // already flipped from waiting to inProgress before the first frame
  // renders - waiting is never actually observable here.
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
        state.errorMessage ?? 'Failed',
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

  // Only called once _hasRun is true, by which point every store has
  // settled to done or failed - waiting/inProgress can't occur here.
  Widget _buildStatusChip(StoreFetchState state) {
    final failed = state.status == StoreFetchStatus.failed;
    return Chip(
      avatar: Icon(
        failed ? Icons.error : Icons.check_circle,
        size: 16,
        color: failed ? Colors.red : Colors.green,
      ),
      label: Text(
        failed ? '${state.store.name} · failed' : '${state.store.name} · ${state.itemCount}',
        style: const TextStyle(fontSize: 12),
      ),
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
      grouped.putIfAbsent(ItemCategorizer.categorize(item.name), () => []).add(item);
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
                  _buildSectionHeader(_sectionLabel(category)),
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
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(item.name)),
          if (item.isCoverPage) ...[const SizedBox(width: 8), _buildCoverBadge()],
        ],
      ),
      subtitle: Text('${item.storeName} · page ${item.pageIndex}'),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(item.price, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (item.unitPrice != null) Text(item.unitPrice!, style: Theme.of(context).textTheme.bodySmall),
        ],
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
