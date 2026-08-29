import 'package:flutter/material.dart';

import '../models/meal_history.dart';
import '../services/meal_history_repository.dart';
import 'history_detail_screen.dart';

/// Lists every manually-saved week's plan, most recent first. Each week
/// opens into [HistoryDetailScreen] to view, edit or delete it.
class HistoryScreen extends StatefulWidget {
  HistoryScreen({super.key, MealHistoryRepository? repository}) : repository = repository ?? MealHistoryRepository();

  final MealHistoryRepository repository;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<MealHistoryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await widget.repository.loadAll();
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _openWeek(MealHistoryEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HistoryDetailScreen(entry: entry, repository: widget.repository)),
    );
    // The detail screen may have edited or deleted this week - reload
    // rather than assuming the list is still accurate.
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: const Text(
                    'No saved weeks yet. Save a plan from the Planif tab to see it here.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) => _buildEntryTile(entries[i]),
            ),
    );
  }

  Widget _buildEntryTile(MealHistoryEntry entry) {
    return ListTile(
      leading: const Icon(Icons.event_note_outlined),
      title: Text(entry.weekId),
      subtitle: Text('${entry.slots.length} slots · saved ${_formatDate(entry.savedAt)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openWeek(entry),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}
