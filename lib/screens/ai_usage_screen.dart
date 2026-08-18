import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/ai_call_log.dart';
import '../services/ai_call_activity.dart';
import '../services/ai_call_log_repository.dart';

class AiUsageScreen extends StatefulWidget {
  AiUsageScreen({super.key, AiCallLogRepository? repository, ValueListenable<List<AiInFlightCall>>? activity})
    : repository = repository ?? AiCallLogRepository(),
      activity = activity ?? AiCallActivity.inFlight;

  final AiCallLogRepository repository;
  final ValueListenable<List<AiInFlightCall>> activity;

  @override
  State<AiUsageScreen> createState() => _AiUsageScreenState();
}

class _AiUsageScreenState extends State<AiUsageScreen> {
  List<AiCallLog>? _logs;
  late int _lastInFlightCount;

  @override
  void initState() {
    super.initState();
    _lastInFlightCount = widget.activity.value.length;
    widget.activity.addListener(_onActivityChanged);
    _load();
  }

  @override
  void dispose() {
    widget.activity.removeListener(_onActivityChanged);
    super.dispose();
  }

  // The in-flight notifier only tracks calls that are still running; a call
  // that just finished drops out of it without saying whether it succeeded
  // or failed. Reload the persisted log whenever the in-flight count shrinks
  // so that finished call shows up here instead of just vanishing from
  // "Running now".
  void _onActivityChanged() {
    final count = widget.activity.value.length;
    if (count < _lastInFlightCount) _load();
    _lastInFlightCount = count;
  }

  Future<void> _load() async {
    final logs = await widget.repository.loadAll();
    if (!mounted) return;
    setState(() => _logs = logs);
  }

  @override
  Widget build(BuildContext context) {
    final logs = _logs;
    return Scaffold(
      appBar: AppBar(title: const Text('AI Usage Log')),
      body: logs == null
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<List<AiInFlightCall>>(
              valueListenable: widget.activity,
              builder: (context, running, _) {
                if (running.isEmpty && logs.isEmpty) {
                  return const Center(child: Text('No AI calls yet.'));
                }
                return ListView(
                  children: [
                    if (running.isNotEmpty) ...[
                      _buildSectionHeader('Running now'),
                      ...running.map(_buildRunningRow),
                      const Divider(height: 1),
                    ],
                    ...logs.map(_buildLogRow),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }

  Widget _buildRunningRow(AiInFlightCall call) {
    return ListTile(
      leading: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      title: Text('${call.storeName} · ${call.model}'),
      subtitle: Text('Started ${_formatTimestamp(call.startedAt)}'),
    );
  }

  Widget _buildLogRow(AiCallLog log) {
    return ListTile(
      leading: Icon(
        log.success ? Icons.check_circle : Icons.error,
        color: log.success ? Colors.green : Colors.red,
      ),
      title: Text('${log.storeName} · ${log.model}'),
      subtitle: Text(
        log.success
            ? '${_formatTimestamp(log.timestamp)} · ${log.inputTokens} in / ${log.outputTokens} out tokens'
            : '${_formatTimestamp(log.timestamp)} · ${log.errorMessage ?? "Failed"}',
      ),
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}
