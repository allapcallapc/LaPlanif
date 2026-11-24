import 'package:flutter/material.dart';

/// Asked before any AI suggestion on the ingredients step: an optional
/// request in the user's own words (e.g. "from the pantry", "a red
/// vegetable") that steers just this one suggestion. [examples] fill the
/// field in one tap. Resolves to the request - empty when left blank - or
/// null when cancelled, in which case nothing should be suggested.
Future<String?> showSuggestionRequestDialog(
  BuildContext context, {
  required String title,
  List<String> examples = const [],
  String actionLabel = 'Suggest',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => SuggestionRequestDialog(title: title, examples: examples, actionLabel: actionLabel),
  );
}

class SuggestionRequestDialog extends StatefulWidget {
  const SuggestionRequestDialog({
    super.key,
    required this.title,
    this.examples = const [],
    this.actionLabel = 'Suggest',
  });

  final String title;
  final List<String> examples;

  /// The confirm button's label, e.g. "Generate" for a recipe.
  final String actionLabel;

  @override
  State<SuggestionRequestDialog> createState() => _SuggestionRequestDialogState();
}

class _SuggestionRequestDialogState extends State<SuggestionRequestDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Anything specific? (optional)',
                hintText: 'e.g. ${widget.examples.isEmpty ? 'from the pantry' : widget.examples.first.toLowerCase()}',
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (widget.examples.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final example in widget.examples)
                    ActionChip(
                      label: Text(example),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        _controller.text = example;
                        _controller.selection = TextSelection.collapsed(offset: example.length);
                      }),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(widget.actionLabel),
        ),
      ],
    );
  }
}
