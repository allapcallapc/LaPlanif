import 'dart:async';

import 'package:flutter/material.dart';

import '../models/meal_plan_config.dart';
import '../services/meal_plan_config_repository.dart';
import '../widgets/meal_plan_config_editor.dart';

class ConfigMealPlanScreen extends StatefulWidget {
  const ConfigMealPlanScreen({super.key, required this.repository});

  final MealPlanConfigRepository repository;

  @override
  State<ConfigMealPlanScreen> createState() => _ConfigMealPlanScreenState();
}

class _ConfigMealPlanScreenState extends State<ConfigMealPlanScreen> {
  MealPlanConfig? _mealPlanConfig;
  Timer? _saveDebounce;
  final _editorKey = GlobalKey<MealPlanConfigEditorState>();

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
    super.dispose();
  }

  Future<void> _loadMealPlanConfig() async {
    final config = await widget.repository.load();
    if (!mounted) return;
    setState(() => _mealPlanConfig = config);
  }

  // The model update (setState) happens immediately so the UI stays
  // responsive, but the SharedPreferences write is debounced so a burst of
  // edits (typing, or several field changes in quick succession) collapses
  // into one round trip.
  void _onEditorChanged(MealPlanConfig updated) {
    setState(() => _mealPlanConfig = updated);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () => widget.repository.save(updated));
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
            onPressed: mealPlanConfig == null ? null : () => _editorKey.currentState?.addSlot(),
          ),
        ],
      ),
      body: mealPlanConfig == null
          ? const Center(child: CircularProgressIndicator())
          : MealPlanConfigEditor(
              key: _editorKey,
              initialConfig: mealPlanConfig,
              onChanged: _onEditorChanged,
              removeSlotDialogContent: 'This removes the meal slot from your weekly plan.',
              showAddSlotHeader: false,
            ),
    );
  }
}
