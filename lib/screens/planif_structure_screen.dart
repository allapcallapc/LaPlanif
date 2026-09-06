import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/meal_plan_config.dart';
import '../models/meal_plan_full.dart';
import '../services/model_fallback_controller.dart';
import '../utils/error_formatting.dart';
import '../widgets/meal_plan_config_editor.dart';
import 'planif_review_screen.dart';
import 'planif_screen.dart';

/// The gate step reached from the deals view's "Preview meal plan" FAB (or
/// reopened via review's "Edit meal plan structure" action): lets the user
/// validate/change what to plan - meal slots, portions, dietary notes -
/// before the AI call behind the actual preview runs. Uses the same
/// MealPlanConfigEditor as ConfigMealPlanScreen (see issue #32), but scoped
/// to this flow's own draft instead of editing the saved config directly:
/// edits here (and the rest of this week's planning flow) are never written
/// to the saved default config on their own, so tweaking the structure for
/// one week never changes what future weeks start from. Each section offers
/// its own "Save as default" action for the user to promote just that piece
/// on demand. Backing out (the platform back button/gesture, same as
/// anywhere else in this flow) discards any edits here without touching
/// what's already confirmed.
class PlanifStructureScreen extends StatefulWidget {
  const PlanifStructureScreen({
    super.key,
    required this.services,
    required this.items,
    required this.apiKey,
    required this.models,
    required this.groundingModels,
    required this.initialConfig,
  });

  final PlanifServices services;
  final List<DealItem> items;
  final String apiKey;
  final List<String> models;
  final List<String> groundingModels;
  final MealPlanConfig initialConfig;

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

  void _onEditorChanged(MealPlanConfig updated) => setState(() => _draft = updated);

  // Loads the saved default, applies just this section's current draft
  // value on top of it, and writes that back - so promoting one section
  // (e.g. dietary notes) as the new default never drags along whatever this
  // week's draft also happens to hold for the other sections.
  Future<void> _saveSectionAsDefault({
    required MealPlanConfig Function(MealPlanConfig savedDefault) apply,
    required String confirmationMessage,
  }) async {
    final savedDefault = await widget.services.mealPlanConfigRepository.load();
    await widget.services.mealPlanConfigRepository.save(apply(savedDefault));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(confirmationMessage)));
  }

  Future<void> _savePortionsAsDefault() => _saveSectionAsDefault(
    apply: (savedDefault) => savedDefault.copyWith(
      portionsPerMeal: _draft.portionsPerMeal,
      diversityWindowDays: _draft.diversityWindowDays,
    ),
    confirmationMessage: 'Saved portions & diversity window as the default for future weeks.',
  );

  Future<void> _saveDietaryNotesAsDefault() => _saveSectionAsDefault(
    apply: (savedDefault) => savedDefault.copyWith(dietaryNotes: _draft.dietaryNotes),
    confirmationMessage: 'Saved planning instructions as the default for future weeks.',
  );

  Future<void> _saveMealSlotsAsDefault() => _saveSectionAsDefault(
    apply: (savedDefault) => savedDefault.copyWith(mealSlots: _draft.mealSlots),
    confirmationMessage: 'Saved meal slots as the default for future weeks.',
  );

  // This week's edits are only ever kept in _draft - runs the preview call
  // straight from it and hands the result to a freshly pushed review
  // screen, without touching the saved default config.
  Future<void> _confirmAndGeneratePreview() async {
    if (_isGenerating) return;
    setState(() => _isGenerating = true);
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
      appBar: AppBar(title: const Text('What to plan')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'Confirm or adjust the meal structure before the AI generates a preview.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: MealPlanConfigEditor(
              initialConfig: _draft,
              onChanged: _onEditorChanged,
              removeSlotDialogContent: 'This removes the meal slot from this plan.',
              slotKeyPrefix: 'structure-',
              onSavePortionsAsDefault: _savePortionsAsDefault,
              onSaveDietaryNotesAsDefault: _saveDietaryNotesAsDefault,
              onSaveMealSlotsAsDefault: _saveMealSlotsAsDefault,
            ),
          ),
        ],
      ),
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
}
