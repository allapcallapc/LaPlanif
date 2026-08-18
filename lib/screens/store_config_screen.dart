import 'package:flutter/material.dart';

import '../models/store_config.dart';
import '../services/store_config_repository.dart';

class StoreConfigScreen extends StatefulWidget {
  const StoreConfigScreen({super.key, required this.repository});

  final StoreConfigRepository repository;

  @override
  State<StoreConfigScreen> createState() => _StoreConfigScreenState();
}

class _StoreConfigScreenState extends State<StoreConfigScreen> {
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
    return Scaffold(
      appBar: AppBar(title: const Text('Stores')),
      body: stores == null
          ? const Center(child: CircularProgressIndicator())
          : stores.isEmpty
          ? const Center(child: Text('No stores configured yet.'))
          : ListView.builder(
              itemCount: stores.length,
              itemBuilder: (context, i) {
                final store = stores[i];
                return ListTile(
                  title: Text(store.name),
                  subtitle: Text(store.useEpicerieVariant ? '${store.slug} (epicerie)' : store.slug),
                  onTap: () => _openEditor(existing: store),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(store),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
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
  late final TextEditingController _slugController;
  late bool _useEpicerieVariant;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _slugController = TextEditingController(text: widget.existing?.slug ?? '');
    _useEpicerieVariant = widget.existing?.useEpicerieVariant ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _slugController.dispose();
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
              controller: _slugController,
              decoration: const InputDecoration(labelText: 'URL slug'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _useEpicerieVariant,
              onChanged: (v) => setState(() => _useEpicerieVariant = v ?? false),
              title: const Text('Use -epicerie URL variant'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final id =
                widget.existing?.id ??
                '${_slugController.text.trim().toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}';
            Navigator.of(context).pop(
              StoreConfig(
                id: id,
                name: _nameController.text.trim(),
                slug: _slugController.text.trim(),
                useEpicerieVariant: _useEpicerieVariant,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
