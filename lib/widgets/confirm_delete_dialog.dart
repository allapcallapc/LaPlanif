import 'package:flutter/material.dart';

/// Shared confirm-before-delete prompt used by every destructive delete
/// action in the app (stores, models, meal slots, ...) so a single tap can
/// never delete something irreversibly - see GitHub issue #33.
Future<bool> confirmDelete(BuildContext context, {required String title, required String content}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
      ],
    ),
  );
  return confirmed ?? false;
}
