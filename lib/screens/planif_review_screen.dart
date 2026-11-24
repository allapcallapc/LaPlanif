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
import '../utils/ingredient_kind.dart';
import '../utils/iso_week.dart';
import '../utils/recipe_deal_items.dart';
import '../widgets/anchor_picker_dialog.dart';
import '../widgets/carb_picker_dialog.dart';
import '../widgets/ingredient_list_dialog.dart';
import '../widgets/meal_slot_full_card.dart';
import '../widgets/suggestion_request_dialog.dart';
import 'planif_screen.dart';
import 'planif_structure_screen.dart';

/// The planning flow's last two steps, in order:
///
/// 1. Ingredients - every meal's suggested deal items on one page, to swap,
///    add, remove or re-suggest until the whole week looks right.
/// 2. Recipes - once the ingredients are confirmed, one meal at a time: each
///    recipe is built around that meal's confirmed items, never dropping
///    one, and may add another deal item it uses (shown as "added by
///    recipe").
///
/// Both steps share this screen's state, so going back from recipes to
/// ingredients (the back button) keeps every recipe whose items aren't then
/// changed. Reached either fresh from [PlanifStructureScreen] (a preview was
/// just generated) or from [PlanifScreen]'s "Continue planning" (a saved
/// draft is being resumed, on whichever step it was left).
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
    this.initialIngredientsConfirmed = false,
  });

  final PlanifServices services;
  final List<DealItem> items;
  final String? apiKey;
  final List<String> models;
  final List<String> groundingModels;
  final MealPlanConfig config;
  final MealPlanPreview initialPreview;
  final List<MealSlotFull?> initialSlotRecipes;
  final bool initialIngredientsConfirmed;

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
  // Drives the swipeable meal cards below the picker strip. Rebuilt (at the
  // current meal) whenever a new PageView takes over - switching steps, or
  // a regenerate that can change the number of meals.
  late PageController _pager;
  // One per picker tile, so swiping to a meal can scroll its tile into view.
  final List<GlobalKey> _tileKeys = [];
  // False on the ingredients step, true on the recipes step.
  late bool _ingredientsConfirmed;
  bool _isGeneratingAll = false;
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
  // Pending per-ingredient suggestion calls: the ingredient being replaced
  // (by identity - AnchorItem has no value equality), or a `slot-role` key
  // for an empty row being filled.
  final Set<Object> _suggestingAnchors = {};
  // Set once "Save this week's plan" has saved the plan to history (and
  // cleared the draft): back then leaves the screen instead of stepping back
  // to the ingredients, which would save the finished plan as a draft again.
  // Any later change to the plan clears it, since the plan then differs from
  // what was saved.
  bool _savedToHistory = false;

  bool get _allSlotsGenerated => _slotRecipes.isNotEmpty && _slotRecipes.every((s) => s != null);

  List<MealSlotFull> get _generatedSlots => _slotRecipes.whereType<MealSlotFull>().toList();

  bool get _busy =>
      _isPreviewLoading ||
      _regeneratingSlots.isNotEmpty ||
      _generatingRecipeSlots.isNotEmpty ||
      _isSavingWeek ||
      _isGeneratingAll ||
      _suggestingAnchors.isNotEmpty;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  // Swaps in a fresh controller starting at the current meal, for the
  // PageView about to be built; the old one is disposed once it's detached.
  void _resetPager() {
    final old = _pager;
    _pager = PageController(initialPage: _reviewIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  // Shows meal [index]: slides the cards there and keeps its tile in view.
  void _showMeal(int index) {
    setState(() => _reviewIndex = index);
    if (_pager.hasClients && (_pager.page?.round() ?? _reviewIndex) != index) {
      _pager.animateToPage(index, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
    _scrollTileIntoView(index);
  }

  void _onPageChanged(int index) {
    if (index == _reviewIndex) return;
    setState(() => _reviewIndex = index);
    _scrollTileIntoView(index);
  }

  void _scrollTileIntoView(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (index >= _tileKeys.length) return;
      final tileContext = _tileKeys[index].currentContext;
      if (tileContext == null) return;
      Scrollable.ensureVisible(
        tileContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _preview = widget.initialPreview;
    _slotRecipes = List.of(widget.initialSlotRecipes);
    _ingredientsConfirmed = widget.initialIngredientsConfirmed;
    if (_ingredientsConfirmed) _reviewIndex = _firstMissingRecipeIndex();
    _pager = PageController(initialPage: _reviewIndex);
    // Persisted immediately so a crash, refresh, or reclaimed tab right
    // after arriving here still has something to resume from Home (see
    // issue #35) - every further mutation below re-saves the same way.
    _saveDraft();
  }

  Future<void> _saveDraft() async {
    if (_savedToHistory && mounted) setState(() => _savedToHistory = false);
    await widget.services.mealPlanDraftRepository
        .save(
          MealPlanDraft(
            config: widget.config,
            preview: _preview,
            slotRecipes: _slotRecipes,
            ingredientsConfirmed: _ingredientsConfirmed,
          ),
        )
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
    final request = await showSuggestionRequestDialog(
      context,
      title: 'Suggest new ingredients for every meal',
      examples: const ['Use what\'s in the pantry', 'Make one meal vegetarian', 'Quick to cook'],
    );
    if (request == null || !mounted) return;

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
          request: request,
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
        _resetPager();
        // A freshly (re)generated preview can have entirely different
        // anchors, and possibly a different number of slots - any per-slot
        // recipes already generated were built against the old ones, so
        // they're stale.
        _slotRecipes = List<MealSlotFull?>.filled(preview.slots.length, null);
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
    final request = await showSuggestionRequestDialog(
      context,
      title: 'Suggest other ingredients for this meal',
      examples: const ['Use what\'s in the pantry', 'Make it vegetarian', 'Something lighter'],
    );
    if (request == null || !mounted) return;

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
          otherSlots: [
            for (var i = 0; i < _preview.slots.length; i++)
              if (i != index) _preview.slots[i],
          ],
          recentlyUsed: recentlyUsed,
          dietaryNotes: widget.config.dietaryNotes,
          request: request,
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

  List<DealItem> _availableDeals() {
    final usedKeys = _usedAnchorKeys();
    return widget.items
        .where((item) => item.preference != DealPreference.excluded)
        .where((item) => !usedKeys.contains(_anchorNameKey(item.name)))
        .toList();
  }

  static DealCategory? _categoryForRole(AnchorRole role) => switch (role) {
    AnchorRole.protein => DealCategory.protein,
    AnchorRole.vegetable => DealCategory.vegetables,
    _ => null,
  };

  Future<void> _swapAnchorItem(int slotIndex, AnchorItem current) async {
    final role = _roleOf(current);
    if (role == AnchorRole.carb) return _chooseCarb(slotIndex);
    final selected = await showIngredientPickerDialog(
      context,
      items: _availableDeals(),
      title: switch (role) {
        AnchorRole.protein => 'Swap the protein',
        AnchorRole.vegetable => 'Swap the vegetable',
        _ => 'Swap this item',
      },
      role: role,
      initialCategory: _categoryForRole(role),
    );
    if (selected == null) return;
    await _replaceAnchor(slotIndex, current, selected);
  }

  // Puts [replacement] where [current] was in the slot (if it's still
  // there) - the slot's recipe no longer matches, so it's dropped.
  Future<void> _replaceAnchor(int slotIndex, AnchorItem current, AnchorItem replacement) async {
    if (!mounted || !_preview.slots[slotIndex].anchorItems.any((a) => identical(a, current))) return;
    if (_rejectDuplicate(slotIndex, replacement, except: current)) return;
    setState(() {
      final slots = [..._preview.slots];
      final slot = slots[slotIndex];
      final anchors = slot.anchorItems.map((a) => identical(a, current) ? replacement : a).toList();
      slots[slotIndex] = slot.copyWith(anchorItems: anchors);
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  static String _emptyRowKey(int slotIndex, AnchorRole role) => '$slotIndex-${role.name}';

  // Asks the AI for another ingredient in place of just this one, playing
  // the same part in the meal - the per-ingredient version of "Suggest
  // others" on the whole meal. With no [current], suggests one for an empty
  // row ([role]) and adds it.
  Future<void> _suggestAnother(int slotIndex, AnchorItem? current, {AnchorRole? role}) async {
    final effectiveRole = current == null ? role! : _roleOf(current);
    final Object key = current ?? _emptyRowKey(slotIndex, effectiveRole);
    final apiKey = widget.apiKey;
    if (apiKey == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Set your Google AI API key in Config first.')));
      return;
    }
    if (_suggestingAnchors.contains(key)) return;
    final noun = switch (effectiveRole) {
      AnchorRole.protein => 'protein',
      AnchorRole.carb => 'carb',
      AnchorRole.vegetable => 'vegetable',
      AnchorRole.other => 'ingredient',
    };
    final request = await showSuggestionRequestDialog(
      context,
      title: current == null ? 'Suggest a $noun' : 'Suggest another $noun',
      examples: [
        'From the pantry',
        ...switch (effectiveRole) {
          AnchorRole.vegetable => const ['A red vegetable', 'A leafy green'],
          AnchorRole.carb => const ['Something lighter', 'A whole grain'],
          AnchorRole.protein => const ['Vegetarian', 'Fish'],
          AnchorRole.other => const <String>[],
        },
        'Something cheaper',
      ],
    );
    if (request == null || !mounted || _suggestingAnchors.contains(key)) return;
    setState(() => _suggestingAnchors.add(key));
    final otherAnchors = [
      for (var i = 0; i < _preview.slots.length; i++)
        if (i != slotIndex) ..._preview.slots[i].anchorItems,
    ];
    final controller = ModelFallbackController(models: widget.models, waitBeforeRetry: widget.services.rateLimitWait);
    try {
      final replacement = await controller.run(
        attempt: (model) => widget.services.previewService.suggestReplacement(
          apiKey: apiKey,
          slot: _preview.slots[slotIndex],
          replacing: current,
          role: effectiveRole,
          items: widget.items,
          alreadyUsedAnchors: otherAnchors,
          dietaryNotes: widget.config.dietaryNotes,
          request: request,
          model: model,
        ),
        onRateLimited: ({required currentModel, nextModel}) {
          if (!context.mounted) return Future.value(RateLimitChoice.retrySame);
          return widget.services.rateLimitPrompt(context, currentModel: currentModel, nextModel: nextModel);
        },
      );
      if (!mounted) return;
      setState(() => _suggestingAnchors.remove(key));
      if (current != null) {
        await _replaceAnchor(slotIndex, current, replacement);
      } else {
        await _appendAnchor(slotIndex, replacement);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _suggestingAnchors.remove(key));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not suggest another: ${stripExceptionPrefix(e)}')));
    }
  }

  Future<void> _addAnchorItem(int slotIndex, {AnchorRole role = AnchorRole.other}) async {
    final selected = await showIngredientPickerDialog(
      context,
      items: _availableDeals(),
      title: switch (role) {
        AnchorRole.protein => 'Choose a protein',
        AnchorRole.vegetable => 'Choose a vegetable',
        _ => 'Add an item',
      },
      role: role,
      initialCategory: _categoryForRole(role),
    );
    if (selected == null) return;

    await _appendAnchor(slotIndex, selected);
  }

  // Whether [slotIndex] already has an item named like [anchor] (other than
  // [except]) - told to the user instead of adding a duplicate.
  bool _rejectDuplicate(int slotIndex, AnchorItem anchor, {AnchorItem? except}) {
    final key = _anchorNameKey(anchor.name);
    final duplicate = _preview.slots[slotIndex].anchorItems.any(
      (a) => !identical(a, except) && _anchorNameKey(a.name) == key,
    );
    if (duplicate && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${anchor.name} is already in this meal.')));
    }
    return duplicate;
  }

  Future<void> _appendAnchor(int slotIndex, AnchorItem anchor) async {
    if (!mounted || _rejectDuplicate(slotIndex, anchor)) return;
    setState(() {
      final slots = [..._preview.slots];
      final anchors = [...slots[slotIndex].anchorItems, anchor];
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

  void _jumpToMeal(int index) => _showMeal(index);

  // Set explicitly by the AI's suggestion or the picker it came from. Only
  // items saved before roles existed fall back to the flyer's category -
  // never for the carb, since extraction can misfile e.g. tofu as a carb.
  AnchorRole _roleOf(AnchorItem anchor) {
    if (anchor.role != null) return anchor.role!;
    final category = _dealFor(anchor)?.category;
    return switch (category) {
      DealCategory.protein => AnchorRole.protein,
      DealCategory.vegetables => AnchorRole.vegetable,
      _ => AnchorRole.other,
    };
  }

  bool _isCarb(AnchorItem anchor) => anchor.isCarb;

  // This week's deal matching [anchor] by name, preferring the same store -
  // for its price and (for old items) its category.
  DealItem? _dealFor(AnchorItem anchor) {
    if (anchor.isPantry) return null;
    final key = _anchorNameKey(anchor.name);
    final matches = widget.items.where((item) => _anchorNameKey(item.name) == key).toList();
    if (matches.isEmpty) return null;
    return matches.firstWhere((item) => item.storeName == anchor.store, orElse: () => matches.first);
  }

  bool _hasCarb(MealSlotPreview slot) => slot.anchorItems.any(_isCarb);

  // Picks (or replaces) a meal's one carb. Deal carbs another meal already
  // anchors on aren't offered, same as the other pickers; pantry staples
  // other meals use are still offered, just flagged.
  Future<void> _chooseCarb(int slotIndex) async {
    final otherAnchors = [
      for (var i = 0; i < _preview.slots.length; i++)
        if (i != slotIndex) ..._preview.slots[i].anchorItems,
    ];
    final otherKeys = {for (final anchor in otherAnchors) _anchorNameKey(anchor.name)};
    final deals = widget.items
        .where((item) => item.category == DealCategory.carbs && item.preference != DealPreference.excluded)
        .where((item) => !otherKeys.contains(_anchorNameKey(item.name)))
        .toList();
    final selected = await showCarbPickerDialog(
      context,
      deals: deals,
      usedElsewhere: {
        for (final anchor in otherAnchors)
          if (_isCarb(anchor)) _anchorNameKey(anchor.name),
      },
    );
    if (selected == null || !mounted) return;

    setState(() {
      final slots = [..._preview.slots];
      final slot = slots[slotIndex];
      slots[slotIndex] = slot.copyWith(
        anchorItems: [
          ...slot.anchorItems.where((a) => !_isCarb(a) && _anchorNameKey(a.name) != _anchorNameKey(selected.name)),
          selected,
        ],
      );
      _preview = MealPlanPreview(slots: slots);
      _slotRecipes[slotIndex] = null;
    });
    await _saveDraft();
  }

  // A side covered by the protein recipe is part of that dish rather than
  // a standalone side, so flag it - otherwise the AI can't tell it apart
  // from an independent side when checking for repeats across the week.
  String _otherMealSideName(MealComponent component) => component.type == MealComponentType.coveredByProtein
      ? '${component.name} (part of the protein recipe)'
      : component.name;

  // The review step's one action for turning a meal's confirmed anchors
  // into (or back into, on a re-run after an anchor edit) a full recipe.
  // Doubles as both "generate" and "regenerate" for a slot - it's the same
  // call either way - so there's only one code path to keep in sync with
  // the card's anchors, unlike a separate preview/full-plan split.
  // The recipe buttons' path: asks for an optional request first (e.g.
  // "something spicy"), then generates. "Generate all" skips the dialog.
  Future<void> _askAndGenerateRecipe(int index) async {
    if (_busy) return;
    final request = await showSuggestionRequestDialog(
      context,
      title: _slotRecipes[index] == null ? 'Generate the recipe' : 'Regenerate the recipe',
      examples: const ['Something spicy', 'Slow cooker', 'Under 30 minutes', 'Simple sides'],
      actionLabel: 'Generate',
    );
    if (request == null || !mounted) return;
    await _generateSlotRecipe(index, request: request);
  }

  Future<void> _generateSlotRecipe(int index, {String request = ''}) async {
    final apiKey = widget.apiKey;
    if (apiKey == null ||
        _isPreviewLoading ||
        _isSavingWeek ||
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
            count: _preview.slots[i].count,
            anchorItems: _preview.slots[i].anchorItems,
            recipeNames: switch (_slotRecipes[i]) {
              null => const [],
              final recipe => [
                recipe.proteinComponent.name,
                _otherMealSideName(recipe.carbComponent),
                _otherMealSideName(recipe.vegetableComponent),
              ],
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
          request: request,
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
        // The recipe may add deal items, never drop a confirmed one - see
        // reconcileRecipeDealItems.
        _slotRecipes[index] = reconcileRecipeDealItems(
          recipe: result.slots.single,
          anchors: _preview.slots[index].anchorItems,
          deals: widget.items,
        );
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

  int _firstMissingRecipeIndex() {
    final index = _slotRecipes.indexWhere((recipe) => recipe == null);
    return index == -1 ? 0 : index;
  }

  // Generates every meal still missing a recipe, one after the other (each
  // one sees the recipes already made for the others, same as tapping them
  // one by one). Stops at the first failure - its snackbar says which.
  Future<void> _generateAllRecipes() async {
    if (_busy) return;
    setState(() => _isGeneratingAll = true);
    for (var i = 0; i < _slotRecipes.length; i++) {
      if (!mounted) return;
      if (_slotRecipes[i] != null) continue;
      _showMeal(i);
      await _generateSlotRecipe(i);
      if (!mounted) return;
      if (_slotRecipes[i] == null) break;
    }
    if (!mounted) return;
    setState(() => _isGeneratingAll = false);
  }

  Future<void> _confirmIngredients() async {
    if (_busy) return;
    final missingCarb = [
      for (final slot in _preview.slots)
        if (!_hasCarb(slot)) '${_capitalize(slot.mealType.name)} · ${slot.protein}',
    ];
    if (missingCarb.isNotEmpty) {
      _showMeal(_preview.slots.indexWhere((slot) => !_hasCarb(slot)));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Choose a carb for: ${missingCarb.join(', ')}')));
      return;
    }
    setState(() {
      _ingredientsConfirmed = true;
      _reviewIndex = _firstMissingRecipeIndex();
      _resetPager();
    });
    await _saveDraft();
  }

  Future<void> _backToIngredients() async {
    setState(() {
      _ingredientsConfirmed = false;
      _resetPager();
    });
    await _saveDraft();
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
    setState(() {
      _isSavingWeek = false;
      _savedToHistory = true;
    });
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
    // On the recipes step, back (app bar arrow or platform gesture) returns
    // to the ingredients step rather than leaving the screen - unless the
    // week was just saved, in which case the plan is done and back leaves.
    return PopScope(
      canPop: !_ingredientsConfirmed || _savedToHistory,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _busy) return;
        _backToIngredients();
      },
      child: _ingredientsConfirmed ? _buildRecipesStep() : _buildIngredientsStep(),
    );
  }

  // --- Step 1: ingredients ------------------------------------------------

  Widget _buildIngredientsStep() {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ingredients'),
        actions: [
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
          const SizedBox(width: 4),
        ],
      ),
      // Same layout as the recipes step: the meal picker strip on top, the
      // selected meal's card below.
      body: Column(
        children: [
          _buildReviewPicker(_preview.slots),
          const Divider(height: 1),
          Expanded(
            child: _buildMealPages(
              (index) => [
                _buildIngredientCard(index, _preview.slots[index]),
                const SizedBox(height: 12),
                Text(
                  'Every meal needs a carb. Tap an ingredient to pick another deal or type your own, or tap ✨ to '
                  'have one suggested. Swipe left or right for the other meals. Recipes keep every ingredient you '
                  'confirm here - they may add another deal item, but never drop one.',
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: FilledButton.icon(
          onPressed: _busy ? null : _confirmIngredients,
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Confirm ingredients'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ),
    );
  }

  Widget _buildIngredientCard(int index, MealSlotPreview slot) {
    final isRegenerating = _regeneratingSlots.contains(index);
    // Read-only while any AI call that changes ingredients is running, so a
    // suggestion can't land on a row filled meanwhile, or repeat something
    // another meal was changed to meanwhile.
    final disabled =
        isRegenerating || _isPreviewLoading || _regeneratingSlots.isNotEmpty || _suggestingAnchors.isNotEmpty;
    final hasRecipe = _slotRecipes[index] != null;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: ValueKey('ingredients-slot-$index'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSlotHeader(slot),
            const SizedBox(height: 8),
            for (final role in const [AnchorRole.protein, AnchorRole.carb, AnchorRole.vegetable, AnchorRole.other])
              _buildRoleRow(index, slot, role, disabled: disabled),
            const SizedBox(height: 8),
            Text(slot.note, style: textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
            Row(
              children: [
                if (hasRecipe) ...[
                  Icon(Icons.check_circle, size: 14, color: Colors.green.shade700),
                  const SizedBox(width: 4),
                  Expanded(child: Text('Recipe ready - changing these items discards it.', style: textTheme.bodySmall)),
                ] else
                  const Spacer(),
                TextButton.icon(
                  onPressed: disabled ? null : () => _regenerateSlot(index),
                  icon: isRegenerating
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 18),
                  label: const Text('Suggest others'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlotHeader(MealSlotPreview slot) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
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
      ],
    );
  }

  static String _roleLabel(AnchorRole role) => switch (role) {
    AnchorRole.protein => 'Protein',
    AnchorRole.carb => 'Carb',
    AnchorRole.vegetable => 'Veg',
    AnchorRole.other => 'Also',
  };

  // The same icons as the recipe step's meal tiles and recipe card.
  static IconData _roleIcon(AnchorRole role) => switch (role) {
    AnchorRole.protein => Icons.set_meal_outlined,
    AnchorRole.carb => Icons.grain,
    AnchorRole.vegetable => Icons.eco_outlined,
    AnchorRole.other => Icons.more_horiz,
  };

  // One line of the card per part of the meal: its item(s), each tappable to
  // swap, or - when there's none - a button to choose one. The carb is
  // required, so its button is red; "Also" holds any extra item and always
  // offers to add one.
  Widget _buildRoleRow(int index, MealSlotPreview slot, AnchorRole role, {required bool disabled}) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final anchors = slot.anchorItems.where((anchor) => _roleOf(anchor) == role).toList();
    final missingCarb = role == AnchorRole.carb && anchors.isEmpty;

    Widget chooseButton(String label, VoidCallback onPressed, {Key? key, Color? color}) => Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: key,
        onPressed: disabled ? null : onPressed,
        icon: Icon(Icons.add, size: 18, color: color),
        label: Text(label, style: TextStyle(color: color)),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
      ),
    );

    return Container(
      key: ValueKey('role-$index-${role.name}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                children: [
                  Icon(_roleIcon(role), size: 22, color: missingCarb ? colorScheme.error : colorScheme.primary),
                  const SizedBox(height: 2),
                  Text(
                    _roleLabel(role),
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: missingCarb ? colorScheme.error : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Keyed by position: two items can share a name (e.g. from an
                // older plan), and sibling keys must be unique.
                for (final (position, anchor) in slot.anchorItems.indexed)
                  if (_roleOf(anchor) == role)
                    KeyedSubtree(
                      key: ValueKey('tile-$index-$position'),
                      child: _buildAnchorTile(index, anchor, disabled: disabled),
                    ),
                if (anchors.isEmpty && role != AnchorRole.other)
                  Row(
                    children: [
                      Flexible(
                        child: missingCarb
                            ? chooseButton(
                                'Choose a carb',
                                () => _chooseCarb(index),
                                key: ValueKey('choose-carb-$index'),
                                color: colorScheme.error,
                              )
                            : chooseButton(
                                role == AnchorRole.protein ? 'Choose a protein' : 'Choose a vegetable',
                                () => _addAnchorItem(index, role: role),
                              ),
                      ),
                      _buildSuggestEmptyButton(index, role, disabled: disabled),
                    ],
                  )
                else if (role == AnchorRole.other)
                  chooseButton('Add item', () => _addAnchorItem(index)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ✨ on an empty row: asks the AI for an ingredient for that part of the
  // meal and adds it.
  Widget _buildSuggestEmptyButton(int index, AnchorRole role, {required bool disabled}) {
    final isSuggesting = _suggestingAnchors.contains(_emptyRowKey(index, role));
    return TextButton.icon(
      key: ValueKey('suggest-$index-${role.name}'),
      onPressed: disabled || isSuggesting ? null : () => _suggestAnother(index, null, role: role),
      icon: isSuggesting
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.auto_awesome, size: 18),
      label: const Text('Suggest'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }

  // The full flyer name (up to two lines - they're often long), with the
  // store and price underneath. Tapping it opens the picker (a deal, or an
  // ingredient typed in); ✨ asks the AI for another; × removes it.
  // The other meals using the same ingredient as [anchor] in this meal -
  // the same name, or the same kind (any rice is rice, chicken thighs and
  // breasts are both chicken; see ingredientKind). A warning only: repeating
  // on purpose is allowed.
  List<String> _repeatsFor(int slotIndex, AnchorItem anchor) {
    final key = _anchorNameKey(anchor.name);
    final kind = ingredientKind(anchor.name);
    bool same(AnchorItem other) =>
        _anchorNameKey(other.name) == key || (kind != null && ingredientKind(other.name) == kind);
    return [
      for (var i = 0; i < _preview.slots.length; i++)
        if (i != slotIndex && _preview.slots[i].anchorItems.any(same))
          '${_capitalize(_preview.slots[i].mealType.name)} · ${_preview.slots[i].protein}',
    ];
  }

  bool _slotHasRepeat(int slotIndex) =>
      _preview.slots[slotIndex].anchorItems.any((anchor) => _repeatsFor(slotIndex, anchor).isNotEmpty);

  Widget _buildAnchorTile(int slotIndex, AnchorItem anchor, {required bool disabled}) {
    final textTheme = Theme.of(context).textTheme;
    final repeats = _repeatsFor(slotIndex, anchor);
    final deal = _dealFor(anchor);
    final isSuggesting = _suggestingAnchors.contains(anchor);
    disabled = disabled || isSuggesting;
    final details = !anchor.isPantry
        ? [anchor.store, ?deal?.priceText].join(' · ')
        : anchor.isCarb
        ? 'Pantry staple'
        : 'Not on sale';
    return InkWell(
      key: ValueKey('anchor-$slotIndex-${anchor.name}'),
      onTap: disabled ? null : () => _swapAnchorItem(slotIndex, anchor),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(anchor.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.bodyMedium),
                  Text(
                    details,
                    style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  if (repeats.isNotEmpty)
                    Row(
                      key: ValueKey('repeat-$slotIndex-${anchor.name}'),
                      children: [
                        Icon(Icons.repeat, size: 14, color: Theme.of(context).colorScheme.tertiary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Also in ${repeats.join(', ')}',
                            style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.tertiary),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            IconButton(
              icon: isSuggesting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome, size: 20),
              tooltip: 'Suggest another',
              visualDensity: VisualDensity.compact,
              onPressed: disabled ? null : () => _suggestAnother(slotIndex, anchor),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Remove',
              visualDensity: VisualDensity.compact,
              onPressed: disabled ? null : () => _removeAnchorItem(slotIndex, anchor),
            ),
          ],
        ),
      ),
    );
  }

  // --- Step 2: recipes ----------------------------------------------------

  Widget _buildRecipesStep() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recipes'),
        actions: [
          if (_allSlotsGenerated)
            IconButton(
              icon: const Icon(Icons.receipt_long_outlined),
              tooltip: 'Extract ingredient list',
              onPressed: () => showIngredientListDialog(context, _generatedSlots),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _buildReviewPicker(_preview.slots),
          const Divider(height: 1),
          Expanded(
            child: _buildMealPages((index) => [_buildRecipeCard(index, _preview.slots[index], _slotRecipes[index])]),
          ),
        ],
      ),
      bottomNavigationBar: _buildRecipesBar(),
    );
  }

  // One page per meal under the picker strip, swiped left/right to move
  // between meals - the same order as the tiles, kept in sync with them.
  Widget _buildMealPages(List<Widget> Function(int index) pageChildren) {
    return PageView.builder(
      key: ValueKey(_ingredientsConfirmed ? 'recipe-pages' : 'ingredient-pages'),
      controller: _pager,
      itemCount: _preview.slots.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) => ListView(
        key: ValueKey('meal-page-$index'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: pageChildren(index),
      ),
    );
  }

  // A picker strip of one tile per meal, pinned above the detail card and
  // never hidden - every meal's name and status stays on screen at all
  // times, and switching which one is shown is a single tap on its tile.
  Widget _buildReviewPicker(List<MealSlotPreview> slots) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          for (var i = 0; i < slots.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            KeyedSubtree(key: _tileKey(i), child: _buildReviewTile(i, slots[i])),
          ],
        ],
      ),
    );
  }

  GlobalKey _tileKey(int index) {
    while (_tileKeys.length <= index) {
      _tileKeys.add(GlobalKey());
    }
    return _tileKeys[index];
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
                if (!_ingredientsConfirmed && !_hasCarb(slot))
                  Icon(Icons.error_outline, size: 13, color: colorScheme.error)
                else if (!_ingredientsConfirmed && _slotHasRepeat(index))
                  Icon(Icons.repeat, size: 13, color: colorScheme.tertiary)
                else if (recipe != null)
                  Icon(Icons.check_circle, size: 13, color: Colors.green.shade700),
              ],
            ),
            const SizedBox(height: 3),
            if (recipe == null) ...[
              _buildReviewTileIngredient(
                Icons.set_meal_outlined,
                slot.anchorItems.where((a) => _roleOf(a) == AnchorRole.protein).map((a) => a.name).firstOrNull ??
                    slot.protein,
              ),
              _buildReviewTileIngredient(
                Icons.grain,
                slot.anchorItems.where(_isCarb).map((a) => a.name).firstOrNull ?? '—',
              ),
              _buildReviewTileIngredient(
                Icons.eco_outlined,
                slot.anchorItems.where((a) => _roleOf(a) == AnchorRole.vegetable).map((a) => a.name).firstOrNull ?? '—',
              ),
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

  // One meal on the recipes step: its confirmed deal items (read-only -
  // they're changed on the ingredients step), plus any the recipe added,
  // then the recipe itself.
  Widget _buildRecipeCard(int index, MealSlotPreview slot, MealSlotFull? recipe) {
    final isGenerating = _generatingRecipeSlots.contains(index);
    final textTheme = Theme.of(context).textTheme;
    final added = recipe == null ? const <AnchorItem>[] : addedDealItems(recipe, slot.anchorItems);

    final Widget recipeBody;
    if (recipe != null) {
      recipeBody = MealSlotFullCard(slot: recipe, onOpenRecipeLink: _openRecipeLink, showHeader: false);
    } else if (isGenerating) {
      recipeBody = Row(
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(child: Text(_recipeGenerationPhaseLabel(_recipeGenerationPhase[index]), style: textTheme.bodySmall)),
        ],
      );
    } else {
      recipeBody = Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _busy ? null : () => _askAndGenerateRecipe(index),
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Generate recipe'),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSlotHeader(slot),
            const SizedBox(height: 12),
            Text('Built around', style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (slot.anchorItems.isEmpty && added.isEmpty) Text('No ingredients', style: textTheme.bodySmall),
                for (final anchor in slot.anchorItems) _buildDealItemChip(anchor, added: false),
                for (final item in added) _buildDealItemChip(item, added: true),
              ],
            ),
            if (added.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('+ added by the recipe, from this week\'s deals', style: textTheme.bodySmall),
            ],
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text('Recipe', style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
                ),
                if (recipe != null)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _askAndGenerateRecipe(index),
                    icon: isGenerating
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 18),
                    label: const Text('Regenerate recipe'),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            recipeBody,
          ],
        ),
      ),
    );
  }

  Widget _buildDealItemChip(AnchorItem item, {required bool added}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Chip(
      key: added ? ValueKey('added-deal-${item.name}') : null,
      avatar: Icon(added ? Icons.add_circle_outline : _roleIcon(_roleOf(item)), size: 16),
      // A pantry item has no store to show.
      label: Text(item.isPantry ? item.name : '${item.name} · ${item.store}'),
      backgroundColor: added ? colorScheme.tertiaryContainer : null,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  String _capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  String _recipeGenerationPhaseLabel(String? phase) => switch (phase) {
    'research' => 'Searching for real recipe links…',
    'extraction' => 'Writing out the recipe…',
    _ => 'Generating…',
  };

  // Until every meal has a recipe, offers to generate the rest in one go;
  // after that, saving the week.
  Widget _buildRecipesBar() {
    if (!_allSlotsGenerated) {
      final remaining = _slotRecipes.where((recipe) => recipe == null).length;
      return SafeArea(
        minimum: const EdgeInsets.all(12),
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _generateAllRecipes,
          icon: _isGeneratingAll
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: Text(_isGeneratingAll ? 'Generating recipes…' : 'Generate all remaining recipes ($remaining)'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      );
    }
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
