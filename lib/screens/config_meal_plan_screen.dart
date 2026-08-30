import 'dart:async';

import 'package:flutter/material.dart';

import '../models/meal_plan_config.dart';
import '../services/meal_plan_config_repository.dart';
import '../widgets/confirm_delete_dialog.dart';

class ConfigMealPlanScreen extends StatefulWidget {
  const ConfigMealPlanScreen({super.key, required this.repository});

  final MealPlanConfigRepository repository;

  @override
  State<ConfigMealPlanScreen> createState() => _ConfigMealPlanScreenState();
}

class _ConfigMealPlanScreenState extends State<ConfigMealPlanScreen> {
  MealPlanConfig? _mealPlanConfig;
  final _portionsController = TextEditingController();
  final _diversityController = TextEditingController();
  final _dietaryNotesController = TextEditingController();
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _loadMealPlanConfig();
  }

  @override
  void dispose() {
    // A pending debounce timer means the last edit was never written to
    // SharedPreferences - flush it instead of just cancelling, or it's
    // silently lost.
    if ((_saveDebounce?.isActive ?? false) && _mealPlanConfig != null) {
      widget.repository.save(_mealPlanConfig!);
    }
    _saveDebounce?.cancel();
    _portionsController.dispose();
    _diversityController.dispose();
    _dietaryNotesController.dispose();
    super.dispose();
  }

  Future<void> _loadMealPlanConfig() async {
    final config = await widget.repository.load();
    if (!mounted) return;
    _portionsController.text = '${config.portionsPerMeal}';
    _diversityController.text = '${config.diversityWindowDays}';
    _dietaryNotesController.text = config.dietaryNotes;
    setState(() => _mealPlanConfig = config);
  }

  // The model update (setState) happens immediately so the UI stays
  // responsive, but the SharedPreferences write is debounced so a burst of
  // edits (typing, or several field changes in quick succession) collapses
  // into one round trip.
  void _saveMealPlanConfig(MealPlanConfig updated) {
    setState(() => _mealPlanConfig = updated);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () => widget.repository.save(updated));
  }

  void _onPortionsChanged(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(portionsPerMeal: parsed));
  }

  void _onDiversityChanged(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(diversityWindowDays: parsed));
  }

  void _onDietaryNotesChanged(String value) {
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(dietaryNotes: value));
  }

  void _addMealSlot() {
    final slots = [
      ..._mealPlanConfig!.mealSlots,
      MealSlot(id: '${DateTime.now().millisecondsSinceEpoch}', mealType: MealType.lunch, protein: 'meat', count: 1),
    ];
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(mealSlots: slots));
  }

  void _updateMealSlot(int index, MealSlot slot) {
    final slots = [..._mealPlanConfig!.mealSlots];
    slots[index] = slot;
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(mealSlots: slots));
  }

  Future<void> _removeMealSlot(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Remove this meal slot?',
      content: 'This removes the meal slot from your weekly plan.',
    );
    if (!confirmed || !mounted) return;
    final slots = [..._mealPlanConfig!.mealSlots]..removeAt(index);
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(mealSlots: slots));
  }

  @override
  Widget build(BuildContext context) {
    final mealPlanConfig = _mealPlanConfig;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meal plan'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add meal slot',
            onPressed: mealPlanConfig == null ? null : _addMealSlot,
          ),
        ],
      ),
      body: mealPlanConfig == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portionsController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Portions per meal'),
                          onChanged: _onPortionsChanged,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _diversityController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Diversity window (days)'),
                          onChanged: _onDiversityChanged,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: TextField(
                    controller: _dietaryNotesController,
                    maxLines: null,
                    minLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Additional planning instructions',
                      hintText: 'e.g. no more than 2 days of fish per week, no red meat',
                    ),
                    onChanged: _onDietaryNotesChanged,
                  ),
                ),
                for (var i = 0; i < mealPlanConfig.mealSlots.length; i++)
                  Builder(
                    builder: (context) {
                      final slot = mealPlanConfig.mealSlots[i];
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: DropdownButtonFormField<MealType>(
                                key: ValueKey('meal-type-${slot.id}'),
                                initialValue: slot.mealType,
                                decoration: const InputDecoration(labelText: 'Meal'),
                                items: MealType.values
                                    .map((t) => DropdownMenuItem(value: t, child: Text(t.name)))
                                    .toList(),
                                onChanged: (value) {
                                  if (value == null) return;
                                  _updateMealSlot(i, slot.copyWith(mealType: value));
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                key: ValueKey('protein-${slot.id}'),
                                initialValue: slot.protein,
                                decoration: const InputDecoration(labelText: 'Protein'),
                                onChanged: (value) {
                                  final trimmed = value.trim();
                                  if (trimmed.isEmpty) return;
                                  _updateMealSlot(i, slot.copyWith(protein: trimmed));
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextFormField(
                                key: ValueKey('count-${slot.id}'),
                                initialValue: '${slot.count}',
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Count'),
                                onChanged: (value) {
                                  final parsed = int.tryParse(value);
                                  if (parsed == null || parsed < 0) return;
                                  _updateMealSlot(i, slot.copyWith(count: parsed));
                                },
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Remove meal slot',
                              onPressed: mealPlanConfig.mealSlots.length == 1 ? null : () => _removeMealSlot(i),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text('${mealPlanConfig.mealsPerWeek} meals / week', style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
    );
  }
}
