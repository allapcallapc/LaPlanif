import 'package:flutter/material.dart';

import '../models/store_config.dart';
import '../services/store_config_repository.dart';
import '../widgets/confirm_delete_dialog.dart';

class ConfigStoresScreen extends StatefulWidget {
  const ConfigStoresScreen({super.key, required this.repository});

  final StoreConfigRepository repository;

  @override
  State<ConfigStoresScreen> createState() => _ConfigStoresScreenState();
}

class _ConfigStoresScreenState extends State<ConfigStoresScreen> {
  List<StoreConfig>? _stores;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stores = await widget.repository.load();
    if (!mounted) return;
    setState(() => _stores = stores);
  }

  Future<void> _openEditor({StoreConfig? existing}) async {
    // Deal items are matched back to a store by display name (see
    // planif_screen._retryStore), so two stores sharing a name would
    // silently corrupt each other's results on retry - block that instead
    // of letting it happen.
    final otherNames = _stores!
        .where((s) => s.id != existing?.id)
        .map((s) => s.name.trim().toLowerCase())
        .toSet();
    final result = await showDialog<StoreConfig>(
      context: context,
      builder: (_) => _StoreEditorDialog(existing: existing, otherNames: otherNames),
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
    final confirmed = await confirmDelete(
      context,
      title: 'Delete this store?',
      content: 'This removes ${store.name} and its flyer link.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _stores!.removeWhere((s) => s.id == store.id));
    await widget.repository.save(_stores!);
  }

  @override
  Widget build(BuildContext context) {
    final stores = _stores;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stores'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add store',
            onPressed: stores == null ? null : () => _openEditor(),
          ),
        ],
      ),
      body: stores == null
          ? const Center(child: CircularProgressIndicator())
          : stores.isEmpty
          ? const Center(child: Text('No stores configured yet.'))
          : ListView(
              children: [
                for (final store in stores)
                  ListTile(
                    title: Text(store.name),
                    subtitle: Text(store.flyerUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => _openEditor(existing: store),
                    trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _remove(store)),
                  ),
              ],
            ),
    );
  }
}

class _StoreEditorDialog extends StatefulWidget {
  const _StoreEditorDialog({this.existing, this.otherNames = const {}});

  final StoreConfig? existing;

  /// Every other configured store's name, trimmed and lowercased. Used to
  /// reject a duplicate name - see the comment in
  /// _ConfigStoresScreenState._openEditor.
  final Set<String> otherNames;

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
              validator: (v) {
                final trimmed = v?.trim() ?? '';
                if (trimmed.isEmpty) return 'Required';
                if (widget.otherNames.contains(trimmed.toLowerCase())) {
                  return 'A store with this name already exists';
                }
                return null;
              },
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
            Navigator.of(
              context,
            ).pop(StoreConfig(id: id, name: _nameController.text.trim(), flyerUrl: _urlController.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
