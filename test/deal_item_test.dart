import 'package:flutter_test/flutter_test.dart';
import 'package:laplanif/models/deal_item.dart';

void main() {
  test('exposes the fields it was constructed with', () {
    const item = DealItem(
      name: 'Poulet',
      price: '3.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 2,
    );

    expect(item.name, 'Poulet');
    expect(item.price, '3.99\$');
    expect(item.unit, 'lb');
    expect(item.category, DealCategory.protein);
    expect(item.storeName, 'IGA');
    expect(item.pageIndex, 2);
    expect(item.preference, DealPreference.neutral);
  });

  test('isCoverPage is true only for page 1', () {
    const cover = DealItem(
      name: 'Poulet',
      price: '3.99\$',
      unit: '',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 1,
    );
    const notCover = DealItem(
      name: 'Poulet',
      price: '3.99\$',
      unit: '',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 2,
    );

    expect(cover.isCoverPage, isTrue);
    expect(notCover.isCoverPage, isFalse);
  });

  test('preferenceKey combines store, name, price and unit', () {
    const item = DealItem(
      name: 'Poulet',
      price: '3.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 2,
    );

    expect(item.preferenceKey, 'IGA::Poulet::3.99\$::lb');
  });

  test('preferenceKey disambiguates same-name items at different prices', () {
    const wholeChicken = DealItem(
      name: 'Poulet',
      price: '3.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 1,
    );
    const thighs = DealItem(
      name: 'Poulet',
      price: '5.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 4,
    );

    expect(wholeChicken.preferenceKey, isNot(thighs.preferenceKey));
  });

  test('copyWith replaces the preference and keeps other fields', () {
    const item = DealItem(
      name: 'Poulet',
      price: '3.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 2,
    );

    final updated = item.copyWith(preference: DealPreference.priority);

    expect(updated.preference, DealPreference.priority);
    expect(updated.name, item.name);
    expect(updated.price, item.price);
    expect(updated.storeName, item.storeName);
    expect(item.preference, DealPreference.neutral, reason: 'original item is unchanged');
  });

  test('copyWith with no preference argument keeps the existing preference', () {
    const item = DealItem(
      name: 'Poulet',
      price: '3.99\$',
      unit: 'lb',
      category: DealCategory.protein,
      storeName: 'IGA',
      pageIndex: 2,
      preference: DealPreference.priority,
    );

    final updated = item.copyWith();

    expect(updated.preference, DealPreference.priority);
  });

  group('DealPreferenceCycle', () {
    test('cycles neutral -> priority -> excluded -> neutral', () {
      expect(DealPreference.neutral.next, DealPreference.priority);
      expect(DealPreference.priority.next, DealPreference.excluded);
      expect(DealPreference.excluded.next, DealPreference.neutral);
    });
  });

  group('DealCategoryLabel', () {
    test('label matches the display name for each category', () {
      expect(DealCategory.protein.label, 'Protein');
      expect(DealCategory.vegetables.label, 'Vegetables');
      expect(DealCategory.carbs.label, 'Carbs');
      expect(DealCategory.uncategorized.label, 'Uncategorized');
    });

    test('fromLabel is case-insensitive', () {
      expect(DealCategoryLabel.fromLabel('protein'), DealCategory.protein);
      expect(DealCategoryLabel.fromLabel('VEGETABLES'), DealCategory.vegetables);
      expect(DealCategoryLabel.fromLabel('Carbs'), DealCategory.carbs);
    });

    test('fromLabel falls back to uncategorized for anything else', () {
      expect(DealCategoryLabel.fromLabel('Snacks'), DealCategory.uncategorized);
      expect(DealCategoryLabel.fromLabel(''), DealCategory.uncategorized);
    });
  });
}
