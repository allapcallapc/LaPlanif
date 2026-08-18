/// Thrown by an operation passed to [ModelFallbackController.run] to signal
/// that the call was rejected for being rate limited (e.g. HTTP 429) and is
/// a candidate for the wait/retry/ask-the-user flow, as opposed to any other
/// failure, which is left to propagate immediately with no retry.
class RateLimitedException implements Exception {
  RateLimitedException(this.model);

  final String model;

  @override
  String toString() => 'RateLimitedException: rate limited on $model';
}

/// What the user chose after being asked what to do about a still-rate-limited
/// call.
enum RateLimitChoice { retrySame, nextModel }

/// Runs an operation against an ordered list of models, applying a reusable
/// rate-limit recovery flow: on [RateLimitedException], wait [waitBeforeRetry]
/// and retry the same model once automatically; if that retry is still rate
/// limited, ask the caller (typically a UI prompt) whether to retry the same
/// model again or fall through to the next one in the list. Any other
/// exception propagates immediately with no retry.
class ModelFallbackController {
  ModelFallbackController({required this.models, this.waitBeforeRetry = const Duration(minutes: 1)})
    : assert(models.isNotEmpty, 'ModelFallbackController requires at least one model');

  final List<String> models;
  final Duration waitBeforeRetry;

  Future<T> run<T>({
    required Future<T> Function(String model) attempt,
    required Future<RateLimitChoice> Function({required String currentModel, String? nextModel}) onRateLimited,
  }) async {
    var modelIndex = 0;
    while (true) {
      final model = models[modelIndex];
      try {
        return await attempt(model);
      } on RateLimitedException {
        // fall through to the automatic cooldown retry below.
      }

      await Future<void>.delayed(waitBeforeRetry);
      try {
        return await attempt(model);
      } on RateLimitedException {
        // still rate limited after the cooldown - ask what to do next.
      }

      final nextModel = modelIndex + 1 < models.length ? models[modelIndex + 1] : null;
      final decision = await onRateLimited(currentModel: model, nextModel: nextModel);
      if (decision == RateLimitChoice.nextModel) {
        // onRateLimited is only ever handed a non-null nextModel to offer
        // this choice for in the first place - a caller returning nextModel
        // when nextModel is null broke that contract, and silently no-oping
        // here would just repeat the same model (and the same question)
        // forever with no way out.
        assert(nextModel != null, 'onRateLimited returned RateLimitChoice.nextModel with no next model available');
        if (nextModel != null) {
          modelIndex++;
        }
      }
    }
  }
}
