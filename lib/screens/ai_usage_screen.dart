import 'package:flutter/material.dart';

import '../models/ai_call_log.dart';
import '../services/ai_call_log_repository.dart';

class AiUsageScreen extends StatefulWidget {
  AiUsageScreen({super.key, AiCallLogRepository? repository})
    : repository = repository ?? AiCallLogRepository();

  final AiCallLogRepository repository;

  @override
  State<AiUsageScreen> createState() => _AiUsageScreenState();
}

class _AiUsageScreenState extends State<AiUsageScreen> {
  List<AiCallLog>? _logs;

  @override
  void initState() {
    super.initState();
    _load();
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
          : logs.isEmpty
          ? const Center(child: Text('No AI calls yet.'))
          : ListView.builder(
              itemCount: logs.length,
              itemBuilder: (context, i) => _buildLogRow(logs[i]),
            ),
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
