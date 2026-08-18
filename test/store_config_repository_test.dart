import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/services/store_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('seeds IGA, Metro and Maxi on first load', () async {
    final repo = StoreConfigRepository();
    final stores = await repo.load();

    expect(stores.map((s) => s.name), containsAll(['IGA', 'Metro', 'Maxi']));
    final iga = stores.firstWhere((s) => s.id == 'iga');
    expect(iga.useEpicerieVariant, isTrue);
    expect(iga.flyerUrl, contains('circulaire-iga-epicerie'));

    final metro = stores.firstWhere((s) => s.id == 'metro');
    expect(metro.useEpicerieVariant, isFalse);
    expect(metro.flyerUrl, contains('circulaire-metro/'));
  });

  test('persists changes between loads', () async {
    final repo = StoreConfigRepository();
    final stores = await repo.load();

    final updated = [
      ...stores,
      const StoreConfig(id: 'super-c', name: 'Super C', slug: 'super-c'),
    ];
    await repo.save(updated);

    final reloaded = await repo.load();
    expect(reloaded.map((s) => s.id), contains('super-c'));
  });
}
