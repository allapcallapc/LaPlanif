import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:laplanif/services/ai_config_repository.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('has no default key', () async {
    final repo = AiConfigRepository();
    expect(await repo.loadApiKey(), isEmpty);
  });

  test('saves and reloads a trimmed key', () async {
    final repo = AiConfigRepository();
    await repo.saveApiKey('  sk-ant-test  ');

    expect(await repo.loadApiKey(), 'sk-ant-test');
  });

  test('saving an empty key clears it', () async {
    final repo = AiConfigRepository();
    await repo.saveApiKey('sk-ant-test');
    await repo.saveApiKey('   ');

    expect(await repo.loadApiKey(), isEmpty);
  });
}
