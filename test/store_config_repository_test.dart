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
    expect(iga.flyerUrl, contains('circulaire-iga-epicerie'));

    final metro = stores.firstWhere((s) => s.id == 'metro');
    expect(metro.flyerUrl, contains('circulaire-metro-speciaux-promotions-et-rabais-de-cette-semaine'));
  });

  test('reseeds defaults when stored data is from an incompatible old schema', () async {
    SharedPreferences.setMockInitialValues({
      'store_configs': '[{"id":"iga","name":"IGA","slug":"iga","useEpicerieVariant":true}]',
    });

    final repo = StoreConfigRepository();
    final stores = await repo.load();

    expect(stores.map((s) => s.name), containsAll(['IGA', 'Metro', 'Maxi']));
  });

  test('first load returns a mutable list', () async {
    final repo = StoreConfigRepository();
    final stores = await repo.load();

    expect(() => stores.removeAt(0), returnsNormally);
  });

  test('persists changes between loads', () async {
    final repo = StoreConfigRepository();
    final stores = await repo.load();

    final updated = [
      ...stores,
      const StoreConfig(id: 'super-c', name: 'Super C', flyerUrl: 'https://example.com/super-c'),
    ];
    await repo.save(updated);

    final reloaded = await repo.load();
    expect(reloaded.map((s) => s.id), contains('super-c'));
  });
}
