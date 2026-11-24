import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/meal_plan_config.dart';
import '../models/meal_plan_full.dart';
import '../models/meal_plan_preview.dart';

/// The in-progress Planif state that would otherwise live only in
/// _PlanifScreenState's fields until "Save this week's plan" is tapped: the
/// confirmed structure, the generated preview, and whichever per-slot
/// recipes have been generated so far (null entries for slots not generated
/// yet, kept parallel to [preview]'s slots).
class MealPlanDraft {
  const MealPlanDraft({
    required this.config,
    required this.preview,
    required this.slotRecipes,
    this.ingredientsConfirmed = false,
  });

  final MealPlanConfig config;
  final MealPlanPreview preview;
  final List<MealSlotFull?> slotRecipes;

  /// Whether the ingredients step was confirmed, i.e. the draft is on the
  /// recipes step - so "Continue planning" resumes on the right one.
  final bool ingredientsConfirmed;

  Map<String, dynamic> toJson() => {
    'config': config.toJson(),
    'preview': preview.toJson(),
    'slotRecipes': slotRecipes.map((r) => r?.toJson()).toList(),
    'ingredientsConfirmed': ingredientsConfirmed,
  };

  factory MealPlanDraft.fromJson(Map<String, dynamic> json) {
    final slotRecipes = (json['slotRecipes'] as List<dynamic>)
        .map((e) => e == null ? null : MealSlotFull.fromJson(e as Map<String, dynamic>))
        .toList();
    final preview = MealPlanPreview.fromJson(json['preview'] as Map<String, dynamic>);
    return MealPlanDraft(
      config: MealPlanConfig.fromJson(json['config'] as Map<String, dynamic>),
      preview: preview,
      slotRecipes: slotRecipes,
      // Drafts saved before the ingredients/recipes split have no flag - one
      // with a recipe already generated was past the ingredients by then,
      // but only resumes there if every meal also has a carb marked, which
      // the ingredients step requires (older drafts never marked one).
      ingredientsConfirmed:
          json['ingredientsConfirmed'] as bool? ??
          (slotRecipes.any((r) => r != null) && preview.slots.every((slot) => slot.anchorItems.any((a) => a.isCarb))),
    );
  }
}

/// Persists the in-progress Planif draft (preview + per-slot recipes) so a
/// crash, refresh, or reclaimed tab doesn't lose a multi-minute, rate-limited
/// AI generation session - see issue #35. Mirrors [DealCacheRepository]'s
/// shape: saved incrementally after each successful generation step,
/// restored on open, and cleared once the week is actually saved to history
/// (at which point there's no more "in progress" work to protect).
class MealPlanDraftRepository {
  static const _prefsKey = 'meal_plan_draft';

  Future<MealPlanDraft?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return null;
    try {
      return MealPlanDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(MealPlanDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(draft.toJson()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
