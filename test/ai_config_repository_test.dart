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

  test('defaults to the built-in model list, gemini-3.5-flash-lite first, when none is configured', () async {
    final repo = AiConfigRepository();
    expect(await repo.loadModels(), AiConfigRepository.defaultModels);
    expect(AiConfigRepository.defaultModels.first, 'gemini-3.5-flash-lite');
  });

  test('saves and reloads a trimmed, ordered model list', () async {
    final repo = AiConfigRepository();
    await repo.saveModels(['  gemini-a  ', 'gemini-b']);

    expect(await repo.loadModels(), ['gemini-a', 'gemini-b']);
  });

  test('drops blank entries when saving models', () async {
    final repo = AiConfigRepository();
    await repo.saveModels(['gemini-a', '   ', 'gemini-b']);

    expect(await repo.loadModels(), ['gemini-a', 'gemini-b']);
  });

  test('saving an empty model list falls back to the default', () async {
    final repo = AiConfigRepository();
    await repo.saveModels(['gemini-a']);
    await repo.saveModels([]);

    expect(await repo.loadModels(), AiConfigRepository.defaultModels);
  });

  test('defaults the grounding-model list to the same list as the general models, when none is configured', () async {
    final repo = AiConfigRepository();
    expect(await repo.loadGroundingModels(), AiConfigRepository.defaultGroundingModels);
    expect(AiConfigRepository.defaultGroundingModels, AiConfigRepository.defaultModels);
  });

  test('saves and reloads a trimmed, ordered grounding-model list', () async {
    final repo = AiConfigRepository();
    await repo.saveGroundingModels(['  gemini-a  ', 'gemini-b']);

    expect(await repo.loadGroundingModels(), ['gemini-a', 'gemini-b']);
  });

  test('drops blank entries when saving grounding models', () async {
    final repo = AiConfigRepository();
    await repo.saveGroundingModels(['gemini-a', '   ', 'gemini-b']);

    expect(await repo.loadGroundingModels(), ['gemini-a', 'gemini-b']);
  });

  test('saving an empty grounding-model list falls back to the default', () async {
    final repo = AiConfigRepository();
    await repo.saveGroundingModels(['gemini-a']);
    await repo.saveGroundingModels([]);

    expect(await repo.loadGroundingModels(), AiConfigRepository.defaultGroundingModels);
  });

  test('the general model list and the grounding-model list are stored independently', () async {
    final repo = AiConfigRepository();
    await repo.saveModels(['gemini-a']);
    await repo.saveGroundingModels(['gemini-b']);

    expect(await repo.loadModels(), ['gemini-a']);
    expect(await repo.loadGroundingModels(), ['gemini-b']);
  });
}
