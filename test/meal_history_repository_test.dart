import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/meal_history.dart';
import 'package:laplanif/models/meal_plan_config.dart';
import 'package:laplanif/models/meal_plan_full.dart';
import 'package:laplanif/models/meal_plan_preview.dart';
import 'package:laplanif/services/meal_history_repository.dart';

MealSlotFull _slot({String recipeName = 'General Tao Chicken', List<AnchorItem> dealItems = const []}) {
  return MealSlotFull(
    mealType: MealType.lunch,
    protein: 'meat',
    count: 5,
    portionsPerMeal: 3,
    proteinComponent: MealComponent(
      type: MealComponentType.link,
      name: recipeName,
      usesWeeklyDeal: dealItems.isNotEmpty,
      dealItems: dealItems,
    ),
    carbComponent: const MealComponent(type: MealComponentType.coveredByProtein, name: 'Rice', usesWeeklyDeal: false),
    vegetableComponent: const MealComponent(type: MealComponentType.simpleSide, name: 'Broccoli', usesWeeklyDeal: false),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loadAll returns an empty list when nothing has been saved yet', () async {
    final repo = MealHistoryRepository();

    expect(await repo.loadAll(), isEmpty);
  });

  test('saveWeek persists an entry that loadAll then returns', () async {
    final repo = MealHistoryRepository();
    final entry = MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [_slot()]);

    await repo.saveWeek(entry);
    final all = await repo.loadAll();

    expect(all.length, 1);
    expect(all.single.weekId, '2026-W34');
    expect(all.single.slots.single.recipeName, 'General Tao Chicken');
  });

  test('saving again for the same weekId overwrites rather than appending', () async {
    final repo = MealHistoryRepository();
    await repo.saveWeek(
      MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [_slot(recipeName: 'First draft')]),
    );
    await repo.saveWeek(
      MealHistoryEntry(
        weekId: '2026-W34',
        savedAt: DateTime.utc(2026, 8, 20, 14, 32),
        slots: [_slot(recipeName: 'Final plan')],
      ),
    );

    final all = await repo.loadAll();

    expect(all.length, 1);
    expect(all.single.slots.single.recipeName, 'Final plan');
  });

  test('loadAll returns entries most recent week first', () async {
    final repo = MealHistoryRepository();
    await repo.saveWeek(MealHistoryEntry(weekId: '2026-W20', savedAt: DateTime.utc(2026, 5, 14), slots: [_slot()]));
    await repo.saveWeek(MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [_slot()]));
    await repo.saveWeek(MealHistoryEntry(weekId: '2026-W28', savedAt: DateTime.utc(2026, 7, 9), slots: [_slot()]));

    final all = await repo.loadAll();

    expect(all.map((e) => e.weekId), ['2026-W34', '2026-W28', '2026-W20']);
  });

  test('deleteWeek removes just that week, leaving the rest', () async {
    final repo = MealHistoryRepository();
    await repo.saveWeek(MealHistoryEntry(weekId: '2026-W20', savedAt: DateTime.utc(2026, 5, 14), slots: [_slot()]));
    await repo.saveWeek(MealHistoryEntry(weekId: '2026-W34', savedAt: DateTime.utc(2026, 8, 20), slots: [_slot()]));

    await repo.deleteWeek('2026-W20');
    final all = await repo.loadAll();

    expect(all.map((e) => e.weekId), ['2026-W34']);
  });

  test('recentlyUsed includes only weeks saved within the diversity window', () async {
    final repo = MealHistoryRepository();
    final now = DateTime.utc(2026, 8, 20);
    await repo.saveWeek(
      MealHistoryEntry(
        weekId: '2026-W33',
        savedAt: now.subtract(const Duration(days: 10)),
        slots: [_slot(recipeName: 'Recent recipe', dealItems: const [AnchorItem(name: 'Chicken thighs', store: 'IGA')])],
      ),
    );
    await repo.saveWeek(
      MealHistoryEntry(
        weekId: '2026-W10',
        savedAt: now.subtract(const Duration(days: 90)),
        slots: [_slot(recipeName: 'Old recipe')],
      ),
    );

    final recent = await repo.recentlyUsed(diversityWindowDays: 28, now: now);

    expect(recent.map((r) => r.recipeName), ['Recent recipe']);
    expect(recent.single.dealItemsUsed.single.name, 'Chicken thighs');
  });

  test('recentlyUsed includes a week exactly at the window boundary', () async {
    final repo = MealHistoryRepository();
    final now = DateTime.utc(2026, 8, 20);
    await repo.saveWeek(
      MealHistoryEntry(
        weekId: '2026-W20',
        savedAt: now.subtract(const Duration(days: 28)),
        slots: [_slot(recipeName: 'Exactly at boundary')],
      ),
    );

    final recent = await repo.recentlyUsed(diversityWindowDays: 28, now: now);

    expect(recent.map((r) => r.recipeName), ['Exactly at boundary']);
  });

  test('recentlyUsed excludes a week one day past the window boundary', () async {
    final repo = MealHistoryRepository();
    final now = DateTime.utc(2026, 8, 20);
    await repo.saveWeek(
      MealHistoryEntry(
        weekId: '2026-W19',
        savedAt: now.subtract(const Duration(days: 29)),
        slots: [_slot(recipeName: 'Just outside the window')],
      ),
    );

    final recent = await repo.recentlyUsed(diversityWindowDays: 28, now: now);

    expect(recent, isEmpty);
  });

  test('reseeds to empty when stored data is from an incompatible schema', () async {
    SharedPreferences.setMockInitialValues({'meal_history': '{"not":"a list"}'});
    final repo = MealHistoryRepository();

    expect(await repo.loadAll(), isEmpty);
  });
}
