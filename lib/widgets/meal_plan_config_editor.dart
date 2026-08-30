import 'package:flutter/material.dart';

import '../models/meal_plan_config.dart';
import 'confirm_delete_dialog.dart';

/// Shared meal-plan editing form: portions/diversity/dietary-notes fields
/// plus the meal-slot rows. Used by both ConfigMealPlanScreen (edits the
/// saved config directly, autosaved by the caller) and
/// PlanifStructureScreen (edits an in-flight draft that's only persisted
/// when the caller explicitly confirms) - see issue #32, where those two
/// screens each had their own copy of this UI and could silently drift
/// apart. Persistence stays with the caller via [onChanged]; this widget
/// only owns the editing state.
class MealPlanConfigEditor extends StatefulWidget {
  const MealPlanConfigEditor({
    super.key,
    required this.initialConfig,
    required this.onChanged,
    required this.removeSlotDialogContent,
    this.slotKeyPrefix = '',
    this.showAddSlotHeader = true,
  });

  final MealPlanConfig initialConfig;
  final ValueChanged<MealPlanConfig> onChanged;

  /// The two call sites word this slightly differently (the saved config
  /// vs. this session's draft), so the caller supplies it.
  final String removeSlotDialogContent;

  /// Prefixes the meal-slot field keys so widget tests can tell the two
  /// call sites' fields apart.
  final String slotKeyPrefix;

  /// Whether to render the "Meal slots" title + inline add button above the
  /// slot rows. ConfigMealPlanScreen instead puts its "add" action in the
  /// AppBar (via the [MealPlanConfigEditorState.addSlot] method, reached
  /// through a GlobalKey) to keep its content within the same height it had
  /// before this widget was extracted.
  final bool showAddSlotHeader;

  @override
  State<MealPlanConfigEditor> createState() => MealPlanConfigEditorState();
}

class MealPlanConfigEditorState extends State<MealPlanConfigEditor> {
  late MealPlanConfig _config;
  final _portionsController = TextEditingController();
  final _diversityController = TextEditingController();
  final _dietaryNotesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _config = widget.initialConfig;
    _portionsController.text = '${_config.portionsPerMeal}';
    _diversityController.text = '${_config.diversityWindowDays}';
    _dietaryNotesController.text = _config.dietaryNotes;
  }

  @override
  void dispose() {
    _portionsController.dispose();
    _diversityController.dispose();
    _dietaryNotesController.dispose();
    super.dispose();
  }

  void _apply(MealPlanConfig updated) {
    setState(() => _config = updated);
    widget.onChanged(updated);
  }

  void _onPortionsChanged(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    _apply(_config.copyWith(portionsPerMeal: parsed));
  }

  void _onDiversityChanged(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    _apply(_config.copyWith(diversityWindowDays: parsed));
  }

  void _onDietaryNotesChanged(String value) {
    _apply(_config.copyWith(dietaryNotes: value));
  }

  void addSlot() {
    final slots = [
      ..._config.mealSlots,
      MealSlot(id: '${DateTime.now().millisecondsSinceEpoch}', mealType: MealType.lunch, protein: 'meat', count: 1),
    ];
    _apply(_config.copyWith(mealSlots: slots));
  }

  void _updateSlot(int index, MealSlot slot) {
    final slots = [..._config.mealSlots];
    slots[index] = slot;
    _apply(_config.copyWith(mealSlots: slots));
  }

  Future<void> _removeSlot(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Remove this meal slot?',
      content: widget.removeSlotDialogContent,
    );
    if (!confirmed || !mounted) return;
    final slots = [..._config.mealSlots]..removeAt(index);
    _apply(_config.copyWith(mealSlots: slots));
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _portionsController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Portions per meal'),
                onChanged: _onPortionsChanged,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _diversityController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Diversity window (days)'),
                onChanged: _onDiversityChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _dietaryNotesController,
          maxLines: null,
          minLines: 2,
          decoration: const InputDecoration(
            labelText: 'Additional planning instructions',
            hintText: 'e.g. no more than 2 days of fish per week, no red meat',
          ),
          onChanged: _onDietaryNotesChanged,
        ),
        const SizedBox(height: 20),
        if (widget.showAddSlotHeader)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Meal slots',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(icon: const Icon(Icons.add), tooltip: 'Add meal slot', onPressed: addSlot),
            ],
          ),
        for (var i = 0; i < config.mealSlots.length; i++)
          _buildSlotRow(i, config.mealSlots[i], config.mealSlots.length),
        const SizedBox(height: 8),
        Text('${config.mealsPerWeek} meals / week', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildSlotRow(int index, MealSlot slot, int slotCount) {
    final prefix = widget.slotKeyPrefix;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<MealType>(
              key: ValueKey('${prefix}meal-type-${slot.id}'),
              initialValue: slot.mealType,
              decoration: const InputDecoration(labelText: 'Meal'),
              items: MealType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.name))).toList(),
              onChanged: (value) {
                if (value == null) return;
                _updateSlot(index, slot.copyWith(mealType: value));
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              key: ValueKey('${prefix}protein-${slot.id}'),
              initialValue: slot.protein,
              decoration: const InputDecoration(labelText: 'Protein'),
              onChanged: (value) {
                final trimmed = value.trim();
                if (trimmed.isEmpty) return;
                _updateSlot(index, slot.copyWith(protein: trimmed));
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              key: ValueKey('${prefix}count-${slot.id}'),
              initialValue: '${slot.count}',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Count'),
              onChanged: (value) {
                final parsed = int.tryParse(value);
                if (parsed == null || parsed < 0) return;
                _updateSlot(index, slot.copyWith(count: parsed));
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove meal slot',
            onPressed: slotCount == 1 ? null : () => _removeSlot(index),
          ),
        ],
      ),
    );
  }
}
