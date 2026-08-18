import 'dart:async';

import 'package:flutter/material.dart';

import '../models/store_config.dart';
import '../services/ai_config_repository.dart';
import '../services/store_config_repository.dart';
import 'ai_usage_screen.dart';

class ConfigScreen extends StatefulWidget {
  ConfigScreen({super.key, required this.repository, AiConfigRepository? aiConfigRepository})
    : aiConfigRepository = aiConfigRepository ?? AiConfigRepository();

  final StoreConfigRepository repository;
  final AiConfigRepository aiConfigRepository;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  List<StoreConfig>? _stores;
  List<String>? _models;
  final _apiKeyController = TextEditingController();
  bool _obscureApiKey = true;
  Timer? _apiKeySaveDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _loadApiKey();
    _loadModels();
  }

  @override
  void dispose() {
    // A pending debounce timer means the last-typed key was never written -
    // flush it instead of just cancelling, or that edit is silently lost.
    if (_apiKeySaveDebounce?.isActive ?? false) {
      widget.aiConfigRepository.saveApiKey(_apiKeyController.text);
    }
    _apiKeySaveDebounce?.cancel();
    _apiKeyController.dispose();
    super.dispose();
  }

  // Saving on every keystroke meant a full SharedPreferences round trip per
  // character; debounce it so a burst of typing collapses into one write
  // shortly after the user pauses.
  void _onApiKeyChanged(String value) {
    _apiKeySaveDebounce?.cancel();
    _apiKeySaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => widget.aiConfigRepository.saveApiKey(value),
    );
  }

  Future<void> _load() async {
    final stores = await widget.repository.load();
    if (!mounted) return;
    setState(() => _stores = stores);
  }

  Future<void> _loadApiKey() async {
    final apiKey = await widget.aiConfigRepository.loadApiKey();
    if (!mounted) return;
    _apiKeyController.text = apiKey;
  }

  Future<void> _loadModels() async {
    final models = await widget.aiConfigRepository.loadModels();
    if (!mounted) return;
    setState(() => _models = models);
  }

  Future<void> _openModelEditor({String? existing, int? index}) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ModelEditorDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _models!.add(result);
      } else {
        _models![index] = result;
      }
    });
    await widget.aiConfigRepository.saveModels(_models!);
  }

  Future<void> _removeModel(int index) async {
    setState(() => _models!.removeAt(index));
    await widget.aiConfigRepository.saveModels(_models!);
  }

  // Only called from the move-up/move-down buttons, which are disabled at
  // the top/bottom of the list, so index + delta is always in range here.
  Future<void> _moveModel(int index, int delta) async {
    setState(() {
      final entry = _models!.removeAt(index);
      _models!.insert(index + delta, entry);
    });
    await widget.aiConfigRepository.saveModels(_models!);
  }

  Future<void> _openEditor({StoreConfig? existing}) async {
    final result = await showDialog<StoreConfig>(
      context: context,
      builder: (_) => _StoreEditorDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      final index = _stores!.indexWhere((s) => s.id == result.id);
      if (index == -1) {
        _stores!.add(result);
      } else {
        _stores![index] = result;
      }
    });
    await widget.repository.save(_stores!);
  }

  Future<void> _remove(StoreConfig store) async {
    setState(() => _stores!.removeWhere((s) => s.id == store.id));
    await widget.repository.save(_stores!);
  }

  @override
  Widget build(BuildContext context) {
    final stores = _stores;
    final models = _models;
    return Scaffold(
      appBar: AppBar(title: const Text('Config')),
      // The whole page scrolls as one region rather than giving the store
      // list its own bounded Expanded pane: with a Models section of
      // variable length below it, a fixed-height pane could squeeze the
      // store list down to where later stores never get laid out.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(child: Text('Stores', style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add store',
                    onPressed: stores == null ? null : () => _openEditor(),
                  ),
                ],
              ),
            ),
          ),
          if (stores == null)
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            )
          else if (stores.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No stores configured yet.'))),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, i) {
                final store = stores[i];
                return ListTile(
                  title: Text(store.name),
                  subtitle: Text(store.flyerUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _openEditor(existing: store),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _remove(store)),
                );
              }, childCount: stores.length),
            ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('AI', style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _apiKeyController,
                obscureText: _obscureApiKey,
                decoration: InputDecoration(
                  labelText: 'Google AI API key',
                  helperText: 'Stored on this device only.',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off),
                    tooltip: _obscureApiKey ? 'Show key' : 'Hide key',
                    onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                  ),
                ),
                onChanged: _onApiKeyChanged,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Models (tried in order)', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add model',
                    onPressed: models == null ? null : () => _openModelEditor(),
                  ),
                ],
              ),
            ),
          ),
          if (models != null)
            SliverList(
              delegate: SliverChildBuilderDelegate((context, i) {
                return ListTile(
                  dense: true,
                  title: Text(models[i]),
                  onTap: () => _openModelEditor(existing: models[i], index: i),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        tooltip: 'Move up',
                        visualDensity: VisualDensity.compact,
                        onPressed: i == 0 ? null : () => _moveModel(i, -1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward),
                        tooltip: 'Move down',
                        visualDensity: VisualDensity.compact,
                        onPressed: i == models.length - 1 ? null : () => _moveModel(i, 1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove model',
                        visualDensity: VisualDensity.compact,
                        // At least one model must stay configured.
                        onPressed: models.length == 1 ? null : () => _removeModel(i),
                      ),
                    ],
                  ),
                );
              }, childCount: models.length),
            ),
          SliverToBoxAdapter(
            child: ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('AI usage log'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiUsageScreen()));
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StoreEditorDialog extends StatefulWidget {
  const _StoreEditorDialog({this.existing});

  final StoreConfig? existing;

  @override
  State<_StoreEditorDialog> createState() => _StoreEditorDialogState();
}

class _StoreEditorDialogState extends State<_StoreEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _urlController = TextEditingController(text: widget.existing?.flyerUrl ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Add store' : 'Edit store'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Display name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Flyer URL', hintText: 'https://...'),
              keyboardType: TextInputType.url,
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return 'Required';
                final uri = Uri.tryParse(value);
                if (uri == null || !uri.isAbsolute) return 'Enter a valid URL';
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final id = widget.existing?.id ?? '${DateTime.now().millisecondsSinceEpoch}';
            Navigator.of(context).pop(
              StoreConfig(id: id, name: _nameController.text.trim(), flyerUrl: _urlController.text.trim()),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ModelEditorDialog extends StatefulWidget {
  const _ModelEditorDialog({this.existing});

  final String? existing;

  @override
  State<_ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _ModelEditorDialogState extends State<_ModelEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _modelController;

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(text: widget.existing ?? '');
  }

  @override
  void dispose() {
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Add model' : 'Edit model'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _modelController,
          decoration: const InputDecoration(labelText: 'Model id', hintText: 'gemini-3.5-flash-lite'),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(_modelController.text.trim());
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
