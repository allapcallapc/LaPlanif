import 'package:flutter/material.dart';

import '../services/model_fallback_controller.dart';

/// Signature of [showRateLimitDialog], so screens can accept an injectable
/// prompt (for testing, or to swap in a different UI) with the same shape.
typedef RateLimitPrompt =
    Future<RateLimitChoice> Function(BuildContext context, {required String currentModel, String? nextModel});

/// Reusable prompt for [ModelFallbackController]'s onRateLimited callback:
/// asks whether to keep retrying [currentModel] or fall through to
/// [nextModel]. Only offers the "next model" choice when one is available -
/// on the last configured model, retrying the same one is the only option.
Future<RateLimitChoice> showRateLimitDialog(
  BuildContext context, {
  required String currentModel,
  String? nextModel,
}) async {
  final choice = await showDialog<RateLimitChoice>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: const Text('Still rate limited'),
      content: Text(
        nextModel == null
            ? '$currentModel is still rate limited. Try again?'
            : '$currentModel is still rate limited. Retry it, or try $nextModel instead?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(RateLimitChoice.retrySame),
          child: Text('Retry $currentModel'),
        ),
        if (nextModel != null)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(RateLimitChoice.nextModel),
            child: Text('Try $nextModel'),
          ),
      ],
    ),
  );
  return choice ?? RateLimitChoice.retrySame;
}
