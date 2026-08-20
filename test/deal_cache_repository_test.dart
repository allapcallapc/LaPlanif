import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/deal_item.dart';
import 'package:laplanif/services/deal_cache_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load returns an empty list when nothing was ever cached', () async {
    final repo = DealCacheRepository();

    expect(await repo.load(), isEmpty);
  });

  test('save then load round-trips the cached items', () async {
    final repo = DealCacheRepository();
    const items = [
      DealItem(
        name: 'Poulet',
        price: '3.99\$',
        unit: 'lb',
        category: DealCategory.protein,
        storeName: 'IGA',
        pageIndex: 2,
      ),
      DealItem(
        name: 'Brocoli',
        price: '2.49\$',
        unit: '',
        category: DealCategory.vegetables,
        storeName: 'Metro',
        pageIndex: 1,
      ),
    ];

    await repo.save(items);
    final loaded = await repo.load();

    expect(loaded.map((i) => i.name), ['Poulet', 'Brocoli']);
    expect(loaded[0].price, '3.99\$');
    expect(loaded[0].unit, 'lb');
    expect(loaded[0].category, DealCategory.protein);
    expect(loaded[0].storeName, 'IGA');
    expect(loaded[0].pageIndex, 2);
  });

  test('clear empties the cache', () async {
    final repo = DealCacheRepository();
    await repo.save(const [
      DealItem(
        name: 'Poulet',
        price: '3.99\$',
        unit: '',
        category: DealCategory.protein,
        storeName: 'IGA',
        pageIndex: 1,
      ),
    ]);

    await repo.clear();

    expect(await repo.load(), isEmpty);
  });

  test('returns an empty list when stored data is from an incompatible old schema', () async {
    SharedPreferences.setMockInitialValues({'deal_cache': '{"not":"a list"}'});

    final repo = DealCacheRepository();

    expect(await repo.load(), isEmpty);
  });
}
