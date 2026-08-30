import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/meal_plan_config.dart';
import '../models/meal_plan_full.dart';
import '../services/model_fallback_controller.dart';
import '../utils/error_formatting.dart';
import '../widgets/confirm_delete_dialog.dart';
import '../widgets/meal_plan_started_bar.dart';
import 'planif_review_screen.dart';
import 'planif_screen.dart';

/// The gate step reached from the deals view's "Preview meal plan" FAB (or
/// reopened via review's "Edit meal plan structure" action): lets the user
/// validate/change what to plan - meal slots, portions, dietary notes -
/// before the AI call behind the actual preview runs. Mirrors
/// ConfigMealPlanScreen, but scoped to this flow's own draft instead of
/// editing the saved config directly. Backing out (the platform back
/// button/gesture, same as anywhere else in this flow) discards any edits
/// here without touching what's already confirmed.
class PlanifStructureScreen extends StatefulWidget {
  const PlanifStructureScreen({
    super.key,
    required this.services,
    required this.items,
    required this.apiKey,
    required this.models,
    required this.groundingModels,
    required this.initialConfig,
    required this.fetchedAt,
  });

  final PlanifServices services;
  final List<DealItem> items;
  final String apiKey;
  final List<String> models;
  final List<String> groundingModels;
  final MealPlanConfig initialConfig;
  final DateTime? fetchedAt;

  @override
  State<PlanifStructureScreen> createState() => _PlanifStructureScreenState();
}

class _PlanifStructureScreenState extends State<PlanifStructureScreen> {
  late MealPlanConfig _draft;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.initialConfig;
  }

  void _updatePortions(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    setState(() => _draft = _draft.copyWith(portionsPerMeal: parsed));
  }

  void _updateDiversity(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    setState(() => _draft = _draft.copyWith(diversityWindowDays: parsed));
  }

  void _updateDietaryNotes(String value) {
    setState(() => _draft = _draft.copyWith(dietaryNotes: value));
  }

  void _addSlot() {
    final slots = [
      ..._draft.mealSlots,
      MealSlot(id: '${DateTime.now().millisecondsSinceEpoch}', mealType: MealType.lunch, protein: 'meat', count: 1),
    ];
    setState(() => _draft = _draft.copyWith(mealSlots: slots));
  }

  void _updateSlot(int index, MealSlot slot) {
    final slots = [..._draft.mealSlots];
    slots[index] = slot;
    setState(() => _draft = _draft.copyWith(mealSlots: slots));
  }

  Future<void> _removeSlot(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Remove this meal slot?',
      content: 'This removes the meal slot from this plan.',
    );
    if (!confirmed || !mounted) return;
    final slots = [..._draft.mealSlots]..removeAt(index);
    setState(() => _draft = _draft.copyWith(mealSlots: slots));
  }

  // Persists the edits so Config screen and any future regenerate call see
  // them too, then runs the preview call and hands the result straight to a
  // freshly pushed review screen.
  Future<void> _confirmAndGeneratePreview() async {
    if (_isGenerating) return;
    setState(() => _isGenerating = true);
    await widget.services.mealPlanConfigRepository.save(_draft);
    final recentlyUsed = await widget.services.mealHistoryRepository.recentlyUsed(
      diversityWindowDays: _draft.diversityWindowDays,
    );

    final controller = ModelFallbackController(models: widget.models, waitBeforeRetry: widget.services.rateLimitWait);
    try {
      final preview = await controller.run(
        attempt: (model) => widget.services.previewService.previewMealPlan(
          apiKey: widget.apiKey,
          mealSlots: _draft.mealSlots,
          portionsPerMeal: _draft.portionsPerMeal,
          items: widget.items,
          recentlyUsed: recentlyUsed,
          dietaryNotes: _draft.dietaryNotes,
          model: model,
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!context.mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.services.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() => _isGenerating = false);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlanifReviewScreen(
            services: widget.services,
            items: widget.items,
            apiKey: widget.apiKey,
            models: widget.models,
            groundingModels: widget.groundingModels,
            config: _draft,
            initialPreview: preview,
            initialSlotRecipes: List<MealSlotFull?>.filled(preview.slots.length, null),
            fetchedAt: widget.fetchedAt,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isGenerating = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not generate preview: ${stripExceptionPrefix(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('What to plan'), bottom: mealPlanStartedBar(context, widget.fetchedAt)),
      body: _buildForm(),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: FilledButton.icon(
          onPressed: _isGenerating ? null : _confirmAndGeneratePreview,
          icon: _isGenerating
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.arrow_forward),
          label: Text(_isGenerating ? 'Generating…' : 'Looks good, generate preview'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final draft = _draft;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        Text(
          'Confirm or adjust the meal structure before the AI generates a preview.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                key: const ValueKey('structure-portions'),
                initialValue: '${draft.portionsPerMeal}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Portions per meal'),
                onChanged: _updatePortions,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                key: const ValueKey('structure-diversity'),
                initialValue: '${draft.diversityWindowDays}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Diversity window (days)'),
                onChanged: _updateDiversity,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('structure-dietary-notes'),
          initialValue: draft.dietaryNotes,
          maxLines: null,
          minLines: 2,
          decoration: const InputDecoration(
            labelText: 'Additional planning instructions',
            hintText: 'e.g. no more than 2 days of fish per week, no red meat',
          ),
          onChanged: _updateDietaryNotes,
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                'Meal slots',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(icon: const Icon(Icons.add), tooltip: 'Add meal slot', onPressed: _addSlot),
          ],
        ),
        for (var i = 0; i < draft.mealSlots.length; i++) _buildSlotRow(i, draft.mealSlots[i], draft.mealSlots.length),
        const SizedBox(height: 8),
        Text('${draft.mealsPerWeek} meals / week', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 72),
      ],
    );
  }

  Widget _buildSlotRow(int index, MealSlot slot, int slotCount) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<MealType>(
              key: ValueKey('structure-meal-type-${slot.id}'),
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
              key: ValueKey('structure-protein-${slot.id}'),
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
              key: ValueKey('structure-count-${slot.id}'),
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
