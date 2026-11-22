import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/models/store_config.dart';
import 'package:laplanif/services/store_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('seeds IGA, Metro, Maxi and Super C on first load', () async {
    final repo = StoreConfigRepository();
    final stores = await repo.load();

    expect(stores.map((s) => s.name), containsAll(['IGA', 'Metro', 'Maxi', 'Super C']));
    final iga = stores.firstWhere((s) => s.id == 'iga');
    expect(iga.flyerUrl, contains('circulaire-iga-epicerie'));

    final metro = stores.firstWhere((s) => s.id == 'metro');
    expect(metro.flyerUrl, contains('circulaire-metro-speciaux-promotions-et-rabais-de-cette-semaine'));

    final superC = stores.firstWhere((s) => s.id == 'super-c');
    expect(superC.flyerUrl, contains('circulaire-super-c/circulaire-semaine-super-c'));
  });

  test('appends Super C once to a list saved before it was a default', () async {
    SharedPreferences.setMockInitialValues({
      'store_configs': '[{"id":"iga","name":"IGA","flyerUrl":"https://example.com/iga"}]',
    });

    final repo = StoreConfigRepository();
    final stores = await repo.load();
    // Only the new default is added - Metro/Maxi were deleted by the user.
    expect(stores.map((s) => s.id), ['iga', 'super-c']);

    // Deleting it afterwards sticks.
    await repo.save(stores.where((s) => s.id != 'super-c').toList());
    final reloaded = await repo.load();
    expect(reloaded.map((s) => s.id), ['iga']);
  });

  test('does not append Super C when the user already added it by hand', () async {
    SharedPreferences.setMockInitialValues({
      'store_configs': '[{"id":"1700000000000","name":"super c","flyerUrl":"https://example.com/sc"}]',
    });

    final stores = await StoreConfigRepository().load();
    expect(stores.map((s) => s.id), ['1700000000000']);
  });

  // Super C is offered once even to a list the user emptied: it's a store
  // they were never given, not one they removed.
  test('offers Super C once to a list emptied before it was a default', () async {
    SharedPreferences.setMockInitialValues({'store_configs': '[]'});

    final repo = StoreConfigRepository();
    expect((await repo.load()).map((s) => s.id), ['super-c']);

    await repo.save([]);
    expect(await repo.load(), isEmpty);
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
      const StoreConfig(id: 'provigo', name: 'Provigo', flyerUrl: 'https://example.com/provigo'),
    ];
    await repo.save(updated);

    final reloaded = await repo.load();
    expect(reloaded.map((s) => s.id), contains('provigo'));
  });
}
