import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/store_config.dart';
import '../services/flyer_scraper_service.dart';
import '../services/store_config_repository.dart';

enum StoreFetchStatus { waiting, inProgress, done, failed }

class StoreFetchState {
  StoreFetchState(this.store);

  final StoreConfig store;
  StoreFetchStatus status = StoreFetchStatus.waiting;
  int itemCount = 0;
  String? errorMessage;
}

class DealsScreen extends StatefulWidget {
  const DealsScreen({super.key, required this.repository});

  final StoreConfigRepository repository;

  @override
  State<DealsScreen> createState() => _DealsScreenState();
}

class _DealsScreenState extends State<DealsScreen> {
  final FlyerScraperService _scraper = FlyerScraperService();

  List<StoreFetchState> _states = [];
  List<DealItem> _items = [];
  bool _isRunning = false;
  bool _hasRun = false;

  Future<void> _fetchAll() async {
    final stores = await widget.repository.load();
    if (!mounted) return;
    setState(() {
      _states = stores.map((s) => StoreFetchState(s)).toList();
      _items = [];
      _isRunning = true;
      _hasRun = false;
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
      final items = await _scraper.fetchDeals(state.store);
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
      appBar: AppBar(title: const Text("This Week's Deals")),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _isRunning ? null : _fetchAll,
              icon: const Icon(Icons.refresh),
              label: Text(_isRunning ? 'Fetching…' : "Fetch this week's deals"),
            ),
          ),
          if (_states.isNotEmpty) ...[
            const Divider(height: 1),
            ..._states.map(_buildStatusRow),
            const Divider(height: 1),
          ],
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildStatusRow(StoreFetchState state) {
    final (icon, trailingText) = switch (state.status) {
      StoreFetchStatus.waiting => (const Icon(Icons.hourglass_empty, color: Colors.grey), 'Waiting'),
      StoreFetchStatus.inProgress => (
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

  Widget _buildResults() {
    if (!_hasRun) {
      return const Center(child: Text('Press "Fetch this week\'s deals" to load flyer items.'));
    }
    if (_items.isEmpty) {
      return const Center(child: Text('No items found.'));
    }
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final item = _items[i];
        return ListTile(
          title: Text(item.name),
          subtitle: Text('${item.storeName} · page ${item.pageIndex}'),
          trailing: Text(item.price, style: const TextStyle(fontWeight: FontWeight.bold)),
        );
      },
    );
  }
}
