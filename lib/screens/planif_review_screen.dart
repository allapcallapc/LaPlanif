import 'package:flutter/material.dart';

import '../models/deal_item.dart';
import '../models/meal_history.dart';
import '../models/meal_plan_config.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';
import '../services/meal_plan_draft_repository.dart';
import '../services/meal_plan_generation_service.dart';
import '../services/model_fallback_controller.dart';
import '../utils/error_formatting.dart';
import '../utils/iso_week.dart';
import '../widgets/ingredient_list_dialog.dart';
import '../widgets/meal_slot_full_card.dart';
import 'planif_screen.dart';
import 'planif_structure_screen.dart';

/// Walks the confirmed slots one meal at a time - anchor items and that
/// meal's full recipe live on the same card, so there's no separate
/// preview/full-plan screen pair to keep in sync by hand. Reached either
/// fresh from [PlanifStructureScreen] (a preview was just generated) or
/// directly from [PlanifScreen]'s "Continue planning" (a saved draft is
/// being resumed) - either way this screen owns its own preview/recipes
/// from here on, independent of wherever it came from.
class PlanifReviewScreen extends StatefulWidget {
  const PlanifReviewScreen({
    super.key,
    required this.services,
    required this.items,
    required this.apiKey,
    required this.models,
    required this.groundingModels,
    required this.config,
    required this.initialPreview,
    required this.initialSlotRecipes,
  });

  final PlanifServices services;
  final List<DealItem> items;
  final String? apiKey;
  final List<String> models;
  final List<String> groundingModels;
  final MealPlanConfig config;
  final MealPlanPreview initialPreview;
  final List<MealSlotFull?> initialSlotRecipes;

  @override
  State<PlanifReviewScreen> createState() => _PlanifReviewScreenState();
}

class _PlanifReviewScreenState extends State<PlanifReviewScreen> {
  late MealPlanPreview _preview;
  // One entry per _preview slot, filled in as each meal's recipe is
  // generated - null means "not generated yet". Kept parallel to
  // _preview.slots rather than a sparse map so index lookups (current review
  // slot, anchor edits invalidating just their own slot) stay simple.
  late List<MealSlotFull?> _slotRecipes;
  int _reviewIndex = 0;
  bool _isPreviewLoading = false;
  bool _isSavingWeek = false;
  final Set<int> _regeneratingSlots = {};
  final Set<int> _generatingRecipeSlots = {};
  // Which of the two AI calls behind _generateSlotRecipe is currently in
  // flight for a given slot ('research' or 'extraction', matching
  // MealPlanGenerationService's onPhase callback) - the research step
  // (searching for and verifying real recipe links) is the slower of the
  // two, so surfacing which one is running keeps the wait from reading as a
  // stuck spinner.
  final Map<int, String> _recipeGenerationPhase = {};
  // Slots whose "Pick the deal items" step has been reopened via Edit after
  // a recipe already exists. Once a recipe is generated, that step collapses
  // to a one-line summary so the recipe gets the card - editing its items
  // again (which discards the recipe) is an explicit opt-in, never a
  // stray tap on a chip.
  final Set<int> _editingAnchorSlots = {};

  bool get _allSlotsGenerated => _slotRecipes.isNotEmpty && _slotRecipes.every((s) => s != null);

  List<MealSlotFull> get _generatedSlots => _slotRecipes.whereType<MealSlotFull>().toList();

  bool get _busy =>
      _isPreviewLoading || _regeneratingSlots.isNotEmpty || _generatingRecipeSlots.isNotEmpty || _isSavingWeek;

  @override
  void initState() {
    super.initState();
    _preview = widget.initialPreview;
    _slotRecipes = List.of(widget.initialSlotRecipes);
    // Persisted immediately so a crash, refresh, or reclaimed tab right
    // after arriving here still has something to resume from Home (see
    // issue #35) - every further mutation below re-saves the same way.
    _saveDraft();
  }

  Future<void> _saveDraft() async {
    await widget.services.mealPlanDraftRepository
        .save(MealPlanDraft(config: widget.config, preview: _preview, slotRecipes: _slotRecipes))
        .catchError((_) {
          // Non-fatal - the in-progress work is still fully usable for this
          // session, just not recoverable if the tab is lost right after.
        });
  }

  // Re-rolls every slot's suggested anchors at once (and clears every
  // generated recipe with them, since a slot's recipe is only ever
  // regenerated one at a time via the review card itself) - a fresh start
  // for the whole week, as opposed to the per-card refresh icon which only
  // touches the one meal it's on.
  Future<void> _regenerateAll() async {
    if (_busy) return;
    final apiKey = widget.apiKey;
    if (apiKey == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }

    final recentlyUsed = await widget.services.mealHistoryRepository.recentlyUsed(
      diversityWindowDays: widget.config.diversityWindowDays,
    );
    setState(() => _isPreviewLoading = true);

    final controller = ModelFallbackController(models: widget.models, waitBeforeRetry: widget.services.rateLimitWait);
    try {
      final preview = await controller.run(
        attempt: (model) => widget.services.previewService.previewMealPlan(
          apiKey: apiKey,
          mealSlots: widget.config.mealSlots,
          portionsPerMeal: widget.config.portionsPerMeal,
          items: widget.items,
          recentlyUsed: recentlyUsed,
          dietaryNotes: widget.config.dietaryNotes,
          model: model,
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!context.mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.services.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _isPreviewLoading = false;
        _reviewIndex = 0;
        // A freshly (re)generated preview can have entirely different
        // anchors, and possibly a different number of slots - any per-slot
        // recipes already generated were built against the old ones, so
        // they're stale.
        _slotRecipes = List<MealSlotFull?>.filled(preview.slots.length, null);
        _editingAnchorSlots.clear();
      });
      await _saveDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPreviewLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not generate preview: ${stripExceptionPrefix(e)}')));
    }
  }

  // Re-runs the AI call for just this one slot and splices the result back
  // into _preview, leaving every other slot's anchors/note untouched.
  Future<void> _regenerateSlot(int index) async {
    final apiKey = widget.apiKey;
    if (apiKey == null || _isPreviewLoading || _regeneratingSlots.contains(index)) return;

    setState(() => _regeneratingSlots.add(index));

    // Every other slot's current anchors, so the regenerated slot doesn't
    // duplicate an ingredient another slot is already using - the AI only
    // sees the one slot being regenerated, unlike the full-plan generate
    // call where every slot (and thus every other slot's picks) is visible
    // in the same request.
    final alreadyUsedAnchors = [
      for (var i = 0; i < _preview.slots.length; i++)
        if (i != index) ..._preview.slots[i].anchorItems,
    ];
    final recentlyUsed = await widget.services.mealHistoryRepository.recentlyUsed(
      diversityWindowDays: widget.config.diversityWindowDays,
    );

    final controller = ModelFallbackController(models: widget.models, waitBeforeRetry: widget.services.rateLimitWait);
    try {
      final result = await controller.run(
        attempt: (model) => widget.services.previewService.previewMealPlan(
          apiKey: apiKey,
          mealSlots: [widget.config.mealSlots[index]],
          portionsPerMeal: widget.config.portionsPerMeal,
          items: widget.items,
          alreadyUsedAnchors: alreadyUsedAnchors,
          recentlyUsed: recentlyUsed,
          dietaryNotes: widget.config.dietaryNotes,
          model: model,
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!context.mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.services.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() {
        final slots = [..._preview.slots];
        slots[index] = result.slots.single;
        _preview = MealPlanPreview(slots: slots);
        _regeneratingSlots.remove(index);
        // Only this slot's anchors changed - any recipe already generated
        // for it no longer matches, but every other slot's recipe is still
        // good.
        _slotRecipes[index] = null;
      });
      await _saveDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() => _regeneratingSlots.remove(index));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not regenerate these suggestions: ${stripExceptionPrefix(e)}')));
    }
  }

  // Normalized by name alone, not name+store: the same ingredient sold at
  // two different stores (e.g. "Brocoli" at IGA and "Brocoli" at Metro)
  // still counts as reusing it, so this can't dedupe on store too.
  String _anchorNameKey(String name) => name.trim().toLowerCase();

  // Every anchor item currently used anywhere in the preview, across every
  // slot - an ingredient shouldn't anchor more than one slot, so neither the
  // swap nor the add picker should offer one already spoken for elsewhere.
  Set<String> _usedAnchorKeys() => {
    for (final slot in _preview.slots)
      for (final anchor in slot.anchorItems) _anchorNameKey(anchor.name),
  };

  Future<void> _swapAnchorItem(int slotIndex, AnchorItem current) async {
    final usedKeys = _usedAnchorKeys();
    final available = widget.items
        .where((item) => item.preference != DealPreference.excluded)
        .where((item) => !usedKeys.contains(_anchorNameKey(item.name)))
        .toList();
    final selected = await showDialog<DealItem>(
      context: context,
      builder: (_) => _AnchorPickerDialog(items: available),
    );
    if (selected == null) return;

    setState(() {
      final slots = [..._preview.slots];
      final slot = slots[slotIndex];
      final anchors = slot.anchorItems
          .map((a) => identical(a, current) ? AnchorItem(name: selected.name, store: selected.storeName) : a)
          .toList();
      slots[slotIndex] = slot.copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  Future<void> _addAnchorItem(int slotIndex) async {
    final usedKeys = _usedAnchorKeys();
    final available = widget.items
        .where((item) => item.preference != DealPreference.excluded)
        .where((item) => !usedKeys.contains(_anchorNameKey(item.name)))
        .toList();
    final selected = await showDialog<DealItem>(
      context: context,
      builder: (_) => _AnchorPickerDialog(items: available, title: 'Add anchor item'),
    );
    if (selected == null) return;

    setState(() {
      final slots = [..._preview.slots];
      final anchors = [...slots[slotIndex].anchorItems, AnchorItem(name: selected.name, store: selected.storeName)];
      slots[slotIndex] = slots[slotIndex].copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  Future<void> _removeAnchorItem(int slotIndex, AnchorItem anchor) async {
    setState(() {
      final slots = [..._preview.slots];
      final slot = slots[slotIndex];
      final anchors = slot.anchorItems.where((a) => !identical(a, anchor)).toList();
      slots[slotIndex] = slot.copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  void _jumpToMeal(int index) => setState(() => _reviewIndex = index);

  // The review step's one action for turning a meal's confirmed anchors
  // into (or back into, on a re-run after an anchor edit) a full recipe.
  // Doubles as both "generate" and "regenerate" for a slot - it's the same
  // call either way - so there's only one code path to keep in sync with
  // the card's anchors, unlike a separate preview/full-plan split.
  Future<void> _generateSlotRecipe(int index) async {
    final apiKey = widget.apiKey;
    if (apiKey == null ||
        _isPreviewLoading ||
        _regeneratingSlots.contains(index) ||
        _generatingRecipeSlots.contains(index)) {
      return;
    }

    setState(() => _generatingRecipeSlots.add(index));

    // Every other meal this week, so the AI generating just this one slot
    // still knows what the rest of the week looks like - deal items can't
    // collide across slots regardless (anchors are already kept distinct),
    // but nothing else stops two independently-generated recipes from
    // landing on the same dish or prep style without this.
    final otherMeals = [
      for (var i = 0; i < _preview.slots.length; i++)
        if (i != index)
          OtherWeekMeal(
            mealType: _preview.slots[i].mealType,
            protein: _preview.slots[i].protein,
            anchorItems: _preview.slots[i].anchorItems,
            recipeNames: switch (_slotRecipes[i]) {
              null => const [],
              final recipe => [recipe.proteinComponent.name, recipe.carbComponent.name, recipe.vegetableComponent.name],
            },
          ),
    ];

    final controller = ModelFallbackController(models: widget.models, waitBeforeRetry: widget.services.rateLimitWait);
    try {
      final result = await controller.run(
        attempt: (model) => widget.services.generationService.generateMealPlan(
          apiKey: apiKey,
          slots: [_preview.slots[index]],
          items: widget.items,
          dietaryNotes: widget.config.dietaryNotes,
          model: model,
          groundingModels: widget.groundingModels,
          otherMeals: otherMeals,
          onPhase: (phase) {
            if (!mounted) return;
            setState(() => _recipeGenerationPhase[index] = phase);
          },
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!context.mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.services.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() {
        _slotRecipes[index] = result.slots.single;
        _editingAnchorSlots.remove(index);
        _generatingRecipeSlots.remove(index);
        _recipeGenerationPhase.remove(index);
      });
      await _saveDraft();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generatingRecipeSlots.remove(index);
        _recipeGenerationPhase.remove(index);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not generate this recipe: ${stripExceptionPrefix(e)}')));
    }
  }

  // Explicit action only - nothing is saved automatically on generation, so
  // re-generating or tweaking a plan before saving never creates a duplicate
  // history entry. Saving again for the same ISO week overwrites that
  // week's entry rather than appending a new one.
  Future<void> _saveWeekPlan() async {
    if (!_allSlotsGenerated || _isSavingWeek) return;

    setState(() => _isSavingWeek = true);
    final entry = MealHistoryEntry(weekId: isoWeekId(DateTime.now()), savedAt: DateTime.now(), slots: _generatedSlots);
    await widget.services.mealHistoryRepository.saveWeek(entry);
    // The plan is committed to history now, so the draft has served its
    // purpose - clearing it means Home's "Continue planning" won't
    // resurface a plan that's already saved.
    await widget.services.mealPlanDraftRepository.clear().catchError((_) {
      // Non-fatal - see comment above.
    });
    if (!mounted) return;
    setState(() => _isSavingWeek = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved this week\'s plan to history.')));
  }

  Future<void> _openRecipeLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await widget.services.launchRecipeLink(uri);
    } catch (_) {
      // Non-fatal: if the platform can't launch it (e.g. no browser handler
      // available), the user still has the URL visible in the card to copy.
    }
  }

  // Re-seeds a fresh structure draft from this review's own confirmed
  // config, and pushes a brand new review screen once confirmed - this
  // screen's own preview/recipes are left exactly as they are, so backing
  // out of structure without confirming (or backing out of the new review
  // screen it leads to) always lands right back here, unchanged.
  Future<void> _openEditStructure() async {
    final apiKey = widget.apiKey;
    if (apiKey == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlanifStructureScreen(
          services: widget.services,
          items: widget.items,
          apiKey: apiKey,
          models: widget.models,
          groundingModels: widget.groundingModels,
          initialConfig: widget.config,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review'), actions: _buildAppBarActions()),
      body: Column(
        children: [
          _buildReviewPicker(_preview.slots),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [_buildReviewCard(_reviewIndex, _preview.slots[_reviewIndex], _slotRecipes[_reviewIndex])],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildReviewBar(),
    );
  }

  List<Widget> _buildAppBarActions() {
    return [
      IconButton(
        icon: const Icon(Icons.tune),
        tooltip: 'Edit meal plan structure',
        onPressed: _busy ? null : _openEditStructure,
      ),
      IconButton(
        icon: _isPreviewLoading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.refresh),
        tooltip: 'Regenerate all suggestions',
        onPressed: _busy ? null : _regenerateAll,
      ),
      if (_allSlotsGenerated)
        IconButton(
          icon: const Icon(Icons.receipt_long_outlined),
          tooltip: 'Extract ingredient list',
          onPressed: () => showIngredientListDialog(context, _generatedSlots),
        ),
      const SizedBox(width: 4),
    ];
  }

  // A picker strip of one tile per meal, pinned above the detail card and
  // never hidden - unlike a stepper, every meal's name and status stays on
  // screen at all times, and switching which one is being edited is a
  // single tap on its tile rather than a forced Back/Next walk through the
  // others.
  Widget _buildReviewPicker(List<MealSlotPreview> slots) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          for (var i = 0; i < slots.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _buildReviewTile(i, slots[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewTile(int index, MealSlotPreview slot) {
    final isCurrent = index == _reviewIndex;
    final recipe = _slotRecipes[index];
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('review-step-$index'),
      onTap: () => _jumpToMeal(index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 124,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isCurrent ? colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isCurrent ? colorScheme.primary : Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(slot.mealType == MealType.lunch ? Icons.wb_sunny_outlined : Icons.nightlight_outlined, size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _capitalize(slot.mealType.name),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (recipe != null) Icon(Icons.check_circle, size: 13, color: Colors.green.shade700),
              ],
            ),
            const SizedBox(height: 3),
            if (recipe == null) ...[
              _buildReviewTileIngredient(
                Icons.set_meal_outlined,
                _anchorForCategory(slot, DealCategory.protein) ?? slot.protein,
              ),
              _buildReviewTileIngredient(Icons.grain, _anchorForCategory(slot, DealCategory.carbs) ?? '—'),
              _buildReviewTileIngredient(Icons.eco_outlined, _anchorForCategory(slot, DealCategory.vegetables) ?? '—'),
            ] else ...[
              _buildReviewTileIngredient(Icons.set_meal_outlined, _tileIngredientLabel(recipe.proteinComponent)),
              _buildReviewTileIngredient(Icons.grain, _tileIngredientLabel(recipe.carbComponent)),
              _buildReviewTileIngredient(Icons.eco_outlined, _tileIngredientLabel(recipe.vegetableComponent)),
            ],
          ],
        ),
      ),
    );
  }

  // The first of this slot's anchor items that's actually filed under
  // [category] in the fetched deals, if any - lets the tile guess at a
  // protein/carb/vegetable breakdown before a recipe (and its own confirmed
  // components) exists yet.
  String? _anchorForCategory(MealSlotPreview slot, DealCategory category) {
    for (final anchor in slot.anchorItems) {
      for (final item in widget.items) {
        if (item.category == category && _anchorNameKey(item.name) == _anchorNameKey(anchor.name)) {
          return anchor.name;
        }
      }
    }
    return null;
  }

  String _tileIngredientLabel(MealComponent component) {
    if (component.dealItems.isNotEmpty) return component.dealItems.first.name;
    return component.name;
  }

  Widget _buildReviewTileIngredient(IconData icon, String name) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icon, size: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Expanded(
            child: Text(name, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
          ),
        ],
      ),
    );
  }

  // The card is laid out as two numbered steps joined by a rail - pick the
  // deal items, then the recipe built from them - so the AI's editable
  // suggestion and the generated result never read as one blur of content.
  // Once a recipe exists, step 1 collapses to a one-line summary and the
  // recipe takes the card; reopening step 1 (Edit) warns that changing the
  // items discards the recipe.
  Widget _buildReviewCard(int index, MealSlotPreview slot, MealSlotFull? recipe) {
    final isRegeneratingAnchors = _regeneratingSlots.contains(index);
    final isGeneratingRecipe = _generatingRecipeSlots.contains(index);
    final anchorsDisabled = isRegeneratingAnchors || isGeneratingRecipe;
    final isEditingAnchors = recipe != null && _editingAnchorSlots.contains(index);
    final anchorsCollapsed = recipe != null && !isEditingAnchors;
    final textTheme = Theme.of(context).textTheme;

    final suggestOthersButton = TextButton.icon(
      onPressed: anchorsDisabled ? null : () => _regenerateSlot(index),
      icon: isRegeneratingAnchors
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh, size: 18),
      label: const Text('Suggest others'),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
    );

    final Widget anchorsTrailing;
    if (anchorsCollapsed) {
      anchorsTrailing = TextButton.icon(
        onPressed: anchorsDisabled ? null : () => setState(() => _editingAnchorSlots.add(index)),
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Edit'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      );
    } else if (isEditingAnchors) {
      anchorsTrailing = TextButton(
        onPressed: () => setState(() => _editingAnchorSlots.remove(index)),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        child: const Text('Done'),
      );
    } else {
      anchorsTrailing = suggestOthersButton;
    }

    final Widget anchorsBody;
    if (anchorsCollapsed) {
      anchorsBody = Text(
        slot.anchorItems.isEmpty ? 'No deal items' : slot.anchorItems.map((a) => a.name).join(' · '),
        style: textTheme.bodySmall,
      );
    } else {
      anchorsBody = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isEditingAnchors) ...[
            _buildDiscardWarning(),
            Align(alignment: Alignment.centerRight, child: suggestOthersButton),
          ] else
            Text('The recipe will be built around these. Tap one to swap it.', style: textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final anchor in slot.anchorItems) _buildAnchorChip(index, anchor, disabled: anchorsDisabled),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Add item'),
                visualDensity: VisualDensity.compact,
                onPressed: anchorsDisabled ? null : () => _addAnchorItem(index),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(slot.note, style: textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
          if (recipe == null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : () => _generateSlotRecipe(index),
              icon: isGeneratingRecipe
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome),
              label: Text(isGeneratingRecipe ? 'Generating…' : 'Generate recipe'),
            ),
          ],
        ],
      );
    }

    final recipeActive = isGeneratingRecipe || anchorsCollapsed;
    final Widget recipeBody;
    if (recipe != null && isEditingAnchors) {
      recipeBody = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Will be replaced if you change the items above.', style: textTheme.bodySmall),
          const SizedBox(height: 8),
          Opacity(
            opacity: 0.45,
            child: MealSlotFullCard(slot: recipe, onOpenRecipeLink: _openRecipeLink, showHeader: false),
          ),
        ],
      );
    } else if (recipe != null) {
      recipeBody = MealSlotFullCard(slot: recipe, onOpenRecipeLink: _openRecipeLink, showHeader: false);
    } else if (isGeneratingRecipe) {
      recipeBody = Row(
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_recipeGenerationPhaseLabel(_recipeGenerationPhase[index]), style: textTheme.bodySmall),
          ),
        ],
      );
    } else {
      recipeBody = Text(
        'Appears here once generated.',
        style: textTheme.bodySmall?.copyWith(color: Theme.of(context).disabledColor),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(slot.mealType == MealType.lunch ? Icons.wb_sunny_outlined : Icons.nightlight_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_capitalize(slot.mealType.name)} · ${slot.protein}',
                    style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text('${slot.totalPortionsNeeded} portions'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text('${slot.count} meals × ${slot.portionsPerMeal} portions', style: textTheme.bodySmall),
            const SizedBox(height: 12),
            _buildStep(
              marker: anchorsCollapsed ? _StepMarker.done : _StepMarker.active,
              number: 1,
              title: 'Pick the deal items',
              trailing: anchorsTrailing,
              body: anchorsBody,
              showRail: true,
            ),
            _buildStep(
              marker: recipeActive ? _StepMarker.active : _StepMarker.upcoming,
              number: 2,
              title: 'Recipe',
              trailing: anchorsCollapsed
                  ? TextButton.icon(
                      onPressed: anchorsDisabled ? null : () => _generateSlotRecipe(index),
                      icon: isGeneratingRecipe
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh, size: 18),
                      label: const Text('Regenerate recipe'),
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    )
                  : null,
              body: recipeBody,
              showRail: false,
            ),
          ],
        ),
      ),
    );
  }

  static const double _stepMarkerSize = 22;

  // One step of the card: a numbered (or checked) marker and title on one
  // row, then the step's body indented under the title. [showRail] draws a
  // line down from the marker, alongside the body, to the next step's
  // marker.
  Widget _buildStep({
    required _StepMarker marker,
    required int number,
    required String title,
    Widget? trailing,
    required Widget body,
    required bool showRail,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final (Color fill, Color border, Color foreground) = switch (marker) {
      _StepMarker.done => (Colors.green.shade700, Colors.green.shade700, Colors.white),
      _StepMarker.active => (colorScheme.primary, colorScheme.primary, colorScheme.onPrimary),
      _StepMarker.upcoming => (Colors.transparent, colorScheme.outlineVariant, colorScheme.onSurfaceVariant),
    };
    const halfMarker = _stepMarkerSize / 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: _stepMarkerSize,
              height: _stepMarkerSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle, border: Border.all(color: border, width: 1.5)),
              child: marker == _StepMarker.done
                  ? Icon(Icons.check, size: 14, color: foreground)
                  : Text(
                      '$number',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: foreground),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: marker == _StepMarker.upcoming ? colorScheme.onSurfaceVariant : null,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        Container(
          margin: const EdgeInsets.only(left: halfMarker - 1),
          padding: EdgeInsets.fromLTRB(halfMarker + 10 - 1, 4, 0, showRail ? 16 : 0),
          decoration: showRail
              ? BoxDecoration(border: Border(left: BorderSide(color: colorScheme.outlineVariant, width: 2)))
              : null,
          child: body,
        ),
      ],
    );
  }

  Widget _buildDiscardWarning() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: colorScheme.onTertiaryContainer),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Changing these items will discard the current recipe. You\'ll generate a new one.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnchorChip(int slotIndex, AnchorItem anchor, {bool disabled = false}) {
    return InputChip(
      avatar: const Icon(Icons.swap_horiz, size: 16),
      label: Text('${anchor.name} · ${anchor.store}'),
      tooltip: 'Tap to swap, or use the × to remove',
      onPressed: disabled ? null : () => _swapAnchorItem(slotIndex, anchor),
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: disabled ? null : () => _removeAnchorItem(slotIndex, anchor),
    );
  }

  String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  String _recipeGenerationPhaseLabel(String? phase) => switch (phase) {
    'research' => 'Searching for real recipe links…',
    'extraction' => 'Writing out the recipe…',
    _ => 'Generating…',
  };

  // The review step's single pinned CTA: saving the week, shown only once
  // every meal has a recipe. Generating a meal's recipe lives inside its
  // card (step 1's button), right above where the recipe will appear, so
  // there's nothing for this bar to do until then.
  Widget _buildReviewBar() {
    if (!_allSlotsGenerated) return const SizedBox.shrink();
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: FilledButton.icon(
        onPressed: _busy ? null : _saveWeekPlan,
        icon: _isSavingWeek
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.save_outlined),
        label: Text(_isSavingWeek ? 'Saving…' : 'Save this week\'s plan'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }
}

class _AnchorPickerDialog extends StatelessWidget {
  const _AnchorPickerDialog({required this.items, this.title = 'Swap anchor item'});

  final List<DealItem> items;
  final String title;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        child: items.isEmpty
            ? const Padding(padding: EdgeInsets.all(8), child: Text('No available deal items.'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  return ListTile(
                    title: Text(item.name),
                    subtitle: Text('${item.storeName} · ${item.priceText}'),
                    onTap: () => Navigator.of(context).pop(item),
                  );
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
    );
  }
}

enum _StepMarker { active, done, upcoming }
