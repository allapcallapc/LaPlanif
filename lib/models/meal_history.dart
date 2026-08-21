import 'meal_plan_full.dart';
import 'meal_plan_preview.dart';

/// One manually-saved snapshot of a week's meal plan - written only by the
/// explicit "Save this week's plan" action, never automatically on
/// generation. One entry per ISO week: saving again for the same [weekId]
/// overwrites this entry rather than adding another one.
class MealHistoryEntry {
  const MealHistoryEntry({required this.weekId, required this.savedAt, required this.slots});

  /// ISO week id (e.g. "2026-W34") identifying which week this plan is for -
  /// see [isoWeekId] in `utils/iso_week.dart`.
  final String weekId;

  final DateTime savedAt;
  final List<MealSlotFull> slots;

  MealHistoryEntry copyWith({DateTime? savedAt, List<MealSlotFull>? slots}) =>
      MealHistoryEntry(weekId: weekId, savedAt: savedAt ?? this.savedAt, slots: slots ?? this.slots);

  Map<String, dynamic> toJson() => {
    'weekId': weekId,
    'savedAt': savedAt.toIso8601String(),
    'slots': slots.map((s) => s.toJson()).toList(),
  };

  factory MealHistoryEntry.fromJson(Map<String, dynamic> json) => MealHistoryEntry(
    weekId: json['weekId'] as String,
    savedAt: DateTime.parse(json['savedAt'] as String),
    slots: (json['slots'] as List<dynamic>).map((s) => MealSlotFull.fromJson(s as Map<String, dynamic>)).toList(),
  );
}

/// One (recipe, deal items) pairing recently used within the diversity
/// window - a soft "try to vary" hint for preview generation, not an
/// exclusion list.
class RecentHistoryItem {
  const RecentHistoryItem({required this.recipeName, required this.dealItemsUsed});

  final String recipeName;
  final List<AnchorItem> dealItemsUsed;
}
