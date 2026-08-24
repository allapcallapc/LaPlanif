import 'package:flutter/material.dart';

import '../models/meal_history.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';
import '../services/meal_history_repository.dart';
import '../utils/iso_week.dart';
import '../widgets/ingredient_list_dialog.dart';
import '../widgets/meal_slot_full_card.dart';
import 'planif_screen.dart' show RecipeLinkLauncher, openRecipeLink;

/// Views and edits one saved week's plan. A slot's recipe name and anchor
/// deal items can be changed manually (reusing [MealSlotFullCard] for
/// display), and the entry can be moved to a different week entirely;
/// re-saving overwrites this week's (or the newly picked week's) history
/// entry, matching the "one plan per week" storage rule.
class HistoryDetailScreen extends StatefulWidget {
  HistoryDetailScreen({
    super.key,
    required this.entry,
    MealHistoryRepository? repository,
    RecipeLinkLauncher? launchRecipeLink,
  }) : repository = repository ?? MealHistoryRepository(),
       launchRecipeLink = launchRecipeLink ?? openRecipeLink;

  final MealHistoryEntry entry;
  final MealHistoryRepository repository;
  final RecipeLinkLauncher launchRecipeLink;

  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  late String _weekId;
  late List<MealSlotFull> _slots;
  bool _isDirty = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _weekId = widget.entry.weekId;
    _slots = List.of(widget.entry.slots);
  }

  Future<void> _openRecipeLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await widget.launchRecipeLink(uri);
    } catch (_) {
      // Non-fatal: if the platform can't launch it (e.g. no browser handler
      // available), the user still has the URL visible in the card to copy.
    }
  }

  Future<void> _editSlot(int index) async {
    final updated = await showDialog<MealSlotFull>(
      context: context,
      builder: (_) => _EditSlotDialog(slot: _slots[index]),
    );
    if (updated == null) return;
    setState(() {
      _slots[index] = updated;
      _isDirty = true;
    });
  }

  // weekId is this entry's identity (the repository's overwrite key), not
  // just another field - "changing" it is really moving the plan to a
  // different week's slot, so a pick that lands on a week another saved
  // entry already occupies needs confirmation before it silently clobbers
  // that other entry on save.
  Future<void> _changeWeek() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: mondayOfIsoWeek(_weekId),
      firstDate: DateTime.utc(2020),
      lastDate: DateTime.now().add(const Duration(days: 730)),
      helpText: 'Pick any date in the target week',
    );
    if (picked == null) return;

    final newWeekId = isoWeekId(picked);
    if (newWeekId == _weekId) return;

    final existing = await widget.repository.loadAll();
    final conflict = existing.any((e) => e.weekId == newWeekId && e.weekId != widget.entry.weekId);
    if (conflict) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Replace existing plan?'),
          content: Text('$newWeekId already has a saved plan. Moving this one there will replace it.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Replace')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _weekId = newWeekId;
      _isDirty = true;
    });
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    final updated = MealHistoryEntry(weekId: _weekId, savedAt: DateTime.now(), slots: _slots);
    await widget.repository.saveWeek(updated);
    // The original entry only needs cleaning up if this save actually moved
    // it to a different week's key - saveWeek above already overwrote the
    // right entry when the week stayed the same.
    if (_weekId != widget.entry.weekId) {
      await widget.repository.deleteWeek(widget.entry.weekId);
    }
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      _isDirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Week updated.')));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this week?'),
        content: Text('This removes the saved plan for ${widget.entry.weekId}. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.repository.deleteWeek(widget.entry.weekId);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_weekId),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined),
            tooltip: 'Extract ingredient list',
            onPressed: () => showIngredientListDialog(context, _slots),
          ),
          IconButton(icon: const Icon(Icons.edit_calendar_outlined), tooltip: 'Change week', onPressed: _changeWeek),
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete this week', onPressed: _delete),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _slots.length,
        itemBuilder: (context, i) => MealSlotFullCard(
          slot: _slots[i],
          onOpenRecipeLink: _openRecipeLink,
          trailing: IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Edit this slot',
            visualDensity: VisualDensity.compact,
            onPressed: () => _editSlot(i),
          ),
        ),
      ),
      bottomNavigationBar: _isDirty
          ? SafeArea(
              minimum: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined),
                label: Text(_isSaving ? 'Saving…' : 'Save changes'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            )
          : null,
    );
  }
}

/// Per-component editable state: name plus the deal items anchoring it.
/// [usesWeeklyDeal] is derived from whether any deal items remain rather
/// than kept as a separate toggle, so it can never drift out of sync with
/// the list a user is actually editing.
class _ComponentEdit {
  _ComponentEdit(MealComponent component)
    : nameController = TextEditingController(text: component.name),
      recipeUrlController = TextEditingController(text: component.recipeUrl ?? ''),
      dealItems = List.of(component.dealItems),
      type = component.type,
      ingredients = component.ingredients,
      instructions = component.instructions,
      note = component.note,
      _originalRecipeUrl = component.recipeUrl,
      _originalRecipeSourceTitle = component.recipeSourceTitle;

  final TextEditingController nameController;
  final TextEditingController recipeUrlController;
  List<AnchorItem> dealItems;
  final MealComponentType type;
  final List<Ingredient> ingredients;
  final List<String> instructions;
  final String note;

  // recipeSourceTitle has no editable field of its own - only the URL is
  // editable here - so it's carried forward as-is when the URL is
  // untouched, and dropped when the user retypes it, since a title that
  // came from grounding no longer describes whatever URL they typed.
  final String? _originalRecipeUrl;
  final String? _originalRecipeSourceTitle;

  MealComponent toComponent() {
    final recipeUrl = recipeUrlController.text.trim().isEmpty ? null : recipeUrlController.text.trim();
    return MealComponent(
      type: type,
      name: nameController.text.trim(),
      recipeUrl: recipeUrl,
      recipeSourceTitle: recipeUrl == _originalRecipeUrl ? _originalRecipeSourceTitle : null,
      ingredients: ingredients,
      instructions: instructions,
      note: note,
      usesWeeklyDeal: dealItems.isNotEmpty,
      dealItems: dealItems,
    );
  }

  void dispose() {
    nameController.dispose();
    recipeUrlController.dispose();
  }
}

class _EditSlotDialog extends StatefulWidget {
  const _EditSlotDialog({required this.slot});

  final MealSlotFull slot;

  @override
  State<_EditSlotDialog> createState() => _EditSlotDialogState();
}

class _EditSlotDialogState extends State<_EditSlotDialog> {
  late final _ComponentEdit _protein;
  late final _ComponentEdit _carb;
  late final _ComponentEdit _vegetable;

  @override
  void initState() {
    super.initState();
    _protein = _ComponentEdit(widget.slot.proteinComponent);
    _carb = _ComponentEdit(widget.slot.carbComponent);
    _vegetable = _ComponentEdit(widget.slot.vegetableComponent);
  }

  @override
  void dispose() {
    _protein.dispose();
    _carb.dispose();
    _vegetable.dispose();
    super.dispose();
  }

  Future<void> _addAnchor(_ComponentEdit component) async {
    final anchor = await showDialog<AnchorItem>(context: context, builder: (_) => const _AnchorEditDialog());
    if (anchor == null) return;
    setState(() => component.dealItems = [...component.dealItems, anchor]);
  }

  Future<void> _editAnchor(_ComponentEdit component, AnchorItem current) async {
    final anchor = await showDialog<AnchorItem>(context: context, builder: (_) => _AnchorEditDialog(existing: current));
    if (anchor == null) return;
    setState(() {
      component.dealItems = component.dealItems.map((a) => identical(a, current) ? anchor : a).toList();
    });
  }

  void _removeAnchor(_ComponentEdit component, AnchorItem anchor) {
    setState(() => component.dealItems = component.dealItems.where((a) => !identical(a, anchor)).toList());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit slot'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildComponentEditor('Protein', _protein),
              const SizedBox(height: 16),
              _buildComponentEditor('Carb', _carb),
              const SizedBox(height: 16),
              _buildComponentEditor('Vegetable', _vegetable),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final updated = widget.slot.copyWith(
              proteinComponent: _protein.toComponent(),
              carbComponent: _carb.toComponent(),
              vegetableComponent: _vegetable.toComponent(),
            );
            Navigator.of(context).pop(updated);
          },
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _buildComponentEditor(String label, _ComponentEdit component) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        TextField(
          controller: component.nameController,
          decoration: const InputDecoration(labelText: 'Recipe name', isDense: true),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: component.recipeUrlController,
          decoration: const InputDecoration(labelText: 'Recipe link (optional)', isDense: true),
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final anchor in component.dealItems)
              InputChip(
                avatar: const Icon(Icons.local_offer_outlined, size: 16),
                label: Text('${anchor.name} · ${anchor.store}'),
                tooltip: 'Tap to edit, or use the × to remove',
                onPressed: () => _editAnchor(component, anchor),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => _removeAnchor(component, anchor),
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('Add anchor'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _addAnchor(component),
            ),
          ],
        ),
      ],
    );
  }
}

class _AnchorEditDialog extends StatefulWidget {
  const _AnchorEditDialog({this.existing});

  final AnchorItem? existing;

  @override
  State<_AnchorEditDialog> createState() => _AnchorEditDialogState();
}

class _AnchorEditDialogState extends State<_AnchorEditDialog> {
  late final _nameController = TextEditingController(text: widget.existing?.name ?? '');
  late final _storeController = TextEditingController(text: widget.existing?.store ?? '');

  @override
  void dispose() {
    _nameController.dispose();
    _storeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add anchor item' : 'Edit anchor item'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Item name')),
          TextField(controller: _storeController, decoration: const InputDecoration(labelText: 'Store')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _nameController.text.trim();
            final store = _storeController.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(AnchorItem(name: name, store: store));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
