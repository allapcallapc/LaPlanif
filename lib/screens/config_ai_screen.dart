import 'dart:async';

import 'package:flutter/material.dart';

import '../services/ai_config_repository.dart';
import '../widgets/confirm_delete_dialog.dart';
import 'ai_usage_screen.dart';

class ConfigAiScreen extends StatefulWidget {
  const ConfigAiScreen({super.key, required this.repository});

  final AiConfigRepository repository;

  @override
  State<ConfigAiScreen> createState() => _ConfigAiScreenState();
}

class _ConfigAiScreenState extends State<ConfigAiScreen> {
  List<String>? _models;
  List<String>? _groundingModels;
  final _apiKeyController = TextEditingController();
  bool _obscureApiKey = true;
  Timer? _apiKeySaveDebounce;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
    _loadModels();
    _loadGroundingModels();
  }

  @override
  void dispose() {
    // A pending debounce timer means the last-typed key was never written -
    // flush it instead of just cancelling, or that edit is silently lost.
    if (_apiKeySaveDebounce?.isActive ?? false) {
      widget.repository.saveApiKey(_apiKeyController.text);
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
    _apiKeySaveDebounce = Timer(const Duration(milliseconds: 500), () => widget.repository.saveApiKey(value));
  }

  Future<void> _loadApiKey() async {
    final apiKey = await widget.repository.loadApiKey();
    if (!mounted) return;
    _apiKeyController.text = apiKey;
  }

  Future<void> _loadModels() async {
    final models = await widget.repository.loadModels();
    if (!mounted) return;
    setState(() => _models = models);
  }

  Future<void> _loadGroundingModels() async {
    final models = await widget.repository.loadGroundingModels();
    if (!mounted) return;
    setState(() => _groundingModels = models);
  }

  Future<void> _openModelEditor({String? existing, int? index}) async {
    final result = await showDialog<String>(context: context, builder: (_) => _ModelEditorDialog(existing: existing));
    if (result == null) return;
    setState(() {
      if (index == null) {
        _models!.add(result);
      } else {
        _models![index] = result;
      }
    });
    await widget.repository.saveModels(_models!);
  }

  Future<void> _removeModel(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Delete this model?',
      content: 'This removes ${_models![index]} from the list.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _models!.removeAt(index));
    await widget.repository.saveModels(_models!);
  }

  // Only called from the move-up/move-down buttons, which are disabled at
  // the top/bottom of the list, so index + delta is always in range here.
  Future<void> _moveModel(int index, int delta) async {
    setState(() {
      final entry = _models!.removeAt(index);
      _models!.insert(index + delta, entry);
    });
    await widget.repository.saveModels(_models!);
  }

  Future<void> _openGroundingModelEditor({String? existing, int? index}) async {
    final result = await showDialog<String>(context: context, builder: (_) => _ModelEditorDialog(existing: existing));
    if (result == null) return;
    setState(() {
      if (index == null) {
        _groundingModels!.add(result);
      } else {
        _groundingModels![index] = result;
      }
    });
    await widget.repository.saveGroundingModels(_groundingModels!);
  }

  Future<void> _removeGroundingModel(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Delete this grounding model?',
      content: 'This removes ${_groundingModels![index]} from the list.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _groundingModels!.removeAt(index));
    await widget.repository.saveGroundingModels(_groundingModels!);
  }

  // Only called from the move-up/move-down buttons, which are disabled at
  // the top/bottom of the list, so index + delta is always in range here.
  Future<void> _moveGroundingModel(int index, int delta) async {
    setState(() {
      final entry = _groundingModels!.removeAt(index);
      _groundingModels!.insert(index + delta, entry);
    });
    await widget.repository.saveGroundingModels(_groundingModels!);
  }

  @override
  Widget build(BuildContext context) {
    final models = _models;
    final groundingModels = _groundingModels;
    return Scaffold(
      appBar: AppBar(title: const Text('AI')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Divider(height: 24)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                Expanded(child: Text('Models (tried in order)', style: Theme.of(context).textTheme.titleSmall)),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add model',
                  onPressed: models == null ? null : () => _openModelEditor(),
                ),
              ],
            ),
          ),
          if (models != null)
            for (var i = 0; i < models.length; i++)
              ListTile(
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
              ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Divider(height: 24)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Grounding search models (tried in order)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add grounding model',
                  onPressed: groundingModels == null ? null : () => _openGroundingModelEditor(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              "Used for the full-plan step's recipe-link search - keep this to models that actually carry a "
              'Search grounding quota on your API key, which can be a narrower set than the models above.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (groundingModels != null)
            for (var i = 0; i < groundingModels.length; i++)
              ListTile(
                dense: true,
                title: Text(groundingModels[i]),
                onTap: () => _openGroundingModelEditor(existing: groundingModels[i], index: i),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: 'Move grounding model up',
                      visualDensity: VisualDensity.compact,
                      onPressed: i == 0 ? null : () => _moveGroundingModel(i, -1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_downward),
                      tooltip: 'Move grounding model down',
                      visualDensity: VisualDensity.compact,
                      onPressed: i == groundingModels.length - 1 ? null : () => _moveGroundingModel(i, 1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove grounding model',
                      visualDensity: VisualDensity.compact,
                      // At least one grounding model must stay configured.
                      onPressed: groundingModels.length == 1 ? null : () => _removeGroundingModel(i),
                    ),
                  ],
                ),
              ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Divider(height: 24)),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('AI usage log'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiUsageScreen()));
            },
          ),
        ],
      ),
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
