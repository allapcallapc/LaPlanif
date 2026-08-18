import 'package:flutter_test/flutter_test.dart';

import 'package:laplanif/services/model_fallback_controller.dart';

void main() {
  test('returns the result on first successful attempt with the first model', () async {
    final controller = ModelFallbackController(models: const ['model-a', 'model-b'], waitBeforeRetry: Duration.zero);
    final calledModels = <String>[];

    final result = await controller.run(
      attempt: (model) async {
        calledModels.add(model);
        return 'ok:$model';
      },
      onRateLimited: ({required currentModel, nextModel}) async => fail('should not be asked'),
    );

    expect(result, 'ok:model-a');
    expect(calledModels, ['model-a']);
  });

  test('waits then retries the same model once automatically, without asking', () async {
    final controller = ModelFallbackController(models: const ['model-a'], waitBeforeRetry: Duration.zero);
    var attempts = 0;

    final result = await controller.run(
      attempt: (model) async {
        attempts++;
        if (attempts == 1) throw RateLimitedException(model);
        return 'ok:$model';
      },
      onRateLimited: ({required currentModel, nextModel}) async => fail('should not be asked'),
    );

    expect(result, 'ok:model-a');
    expect(attempts, 2);
  });

  test('asks the user when still rate limited after the automatic retry', () async {
    final controller = ModelFallbackController(models: const ['model-a', 'model-b'], waitBeforeRetry: Duration.zero);
    var attemptsOnA = 0;
    var promptCalls = 0;

    final result = await controller.run(
      attempt: (model) async {
        if (model == 'model-a') {
          attemptsOnA++;
          throw RateLimitedException(model);
        }
        return 'ok:$model';
      },
      onRateLimited: ({required currentModel, nextModel}) async {
        promptCalls++;
        expect(currentModel, 'model-a');
        expect(nextModel, 'model-b');
        return RateLimitChoice.nextModel;
      },
    );

    expect(attemptsOnA, 2);
    expect(promptCalls, 1);
    expect(result, 'ok:model-b');
  });

  test('retries the same model again when the user chooses retrySame', () async {
    final controller = ModelFallbackController(models: const ['model-a'], waitBeforeRetry: Duration.zero);
    var attempts = 0;
    var promptCalls = 0;

    final result = await controller.run(
      attempt: (model) async {
        attempts++;
        if (attempts <= 2) throw RateLimitedException(model);
        return 'ok:$model';
      },
      onRateLimited: ({required currentModel, nextModel}) async {
        promptCalls++;
        return RateLimitChoice.retrySame;
      },
    );

    expect(attempts, 3);
    expect(promptCalls, 1);
    expect(result, 'ok:model-a');
  });

  test('passes a null nextModel when already on the last configured model', () async {
    final controller = ModelFallbackController(models: const ['only-model'], waitBeforeRetry: Duration.zero);
    var attempts = 0;

    final result = await controller.run(
      attempt: (model) async {
        attempts++;
        if (attempts <= 2) throw RateLimitedException(model);
        return 'ok:$model';
      },
      onRateLimited: ({required currentModel, nextModel}) async {
        expect(nextModel, isNull);
        return RateLimitChoice.retrySame;
      },
    );

    expect(result, 'ok:only-model');
  });

  test('propagates a non-RateLimitedException immediately without retrying or asking', () async {
    final controller = ModelFallbackController(models: const ['model-a', 'model-b'], waitBeforeRetry: Duration.zero);
    var attempts = 0;

    await expectLater(
      controller.run(
        attempt: (model) async {
          attempts++;
          throw Exception('boom');
        },
        onRateLimited: ({required currentModel, nextModel}) async => fail('should not be asked'),
      ),
      throwsA(isA<Exception>()),
    );

    expect(attempts, 1);
  });
}
