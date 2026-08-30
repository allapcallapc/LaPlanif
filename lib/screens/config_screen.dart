import 'dart:async';

import 'package:flutter/material.dart';

import '../models/meal_plan_config.dart';
import '../models/store_config.dart';
import '../services/ai_config_repository.dart';
import '../services/meal_plan_config_repository.dart';
import '../services/store_config_repository.dart';
import '../widgets/confirm_delete_dialog.dart';
import 'ai_usage_screen.dart';

class ConfigScreen extends StatefulWidget {
  ConfigScreen({
    super.key,
    required this.repository,
    AiConfigRepository? aiConfigRepository,
    MealPlanConfigRepository? mealPlanConfigRepository,
  }) : aiConfigRepository = aiConfigRepository ?? AiConfigRepository(),
       mealPlanConfigRepository = mealPlanConfigRepository ?? MealPlanConfigRepository();

  final StoreConfigRepository repository;
  final AiConfigRepository aiConfigRepository;
  final MealPlanConfigRepository mealPlanConfigRepository;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  List<StoreConfig>? _stores;
  List<String>? _models;
  List<String>? _groundingModels;
  MealPlanConfig? _mealPlanConfig;
  final _apiKeyController = TextEditingController();
  final _portionsController = TextEditingController();
  final _diversityController = TextEditingController();
  final _dietaryNotesController = TextEditingController();
  bool _obscureApiKey = true;
  Timer? _apiKeySaveDebounce;
  Timer? _mealPlanSaveDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _loadApiKey();
    _loadModels();
    _loadGroundingModels();
    _loadMealPlanConfig();
  }

  @override
  void dispose() {
    // A pending debounce timer means the last-typed key was never written -
    // flush it instead of just cancelling, or that edit is silently lost.
    if (_apiKeySaveDebounce?.isActive ?? false) {
      widget.aiConfigRepository.saveApiKey(_apiKeyController.text);
    }
    _apiKeySaveDebounce?.cancel();
    // Same reasoning as the API key flush above: a pending meal-plan
    // debounce means the last edit was never written to SharedPreferences.
    if ((_mealPlanSaveDebounce?.isActive ?? false) && _mealPlanConfig != null) {
      widget.mealPlanConfigRepository.save(_mealPlanConfig!);
    }
    _mealPlanSaveDebounce?.cancel();
    _apiKeyController.dispose();
    _portionsController.dispose();
    _diversityController.dispose();
    _dietaryNotesController.dispose();
    super.dispose();
  }

  // Saving on every keystroke meant a full SharedPreferences round trip per
  // character; debounce it so a burst of typing collapses into one write
  // shortly after the user pauses.
  void _onApiKeyChanged(String value) {
    _apiKeySaveDebounce?.cancel();
    _apiKeySaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => widget.aiConfigRepository.saveApiKey(value),
    );
  }

  Future<void> _load() async {
    final stores = await widget.repository.load();
    if (!mounted) return;
    setState(() => _stores = stores);
  }

  Future<void> _loadApiKey() async {
    final apiKey = await widget.aiConfigRepository.loadApiKey();
    if (!mounted) return;
    _apiKeyController.text = apiKey;
  }

  Future<void> _loadModels() async {
    final models = await widget.aiConfigRepository.loadModels();
    if (!mounted) return;
    setState(() => _models = models);
  }

  Future<void> _loadGroundingModels() async {
    final models = await widget.aiConfigRepository.loadGroundingModels();
    if (!mounted) return;
    setState(() => _groundingModels = models);
  }

  Future<void> _loadMealPlanConfig() async {
    final config = await widget.mealPlanConfigRepository.load();
    if (!mounted) return;
    _portionsController.text = '${config.portionsPerMeal}';
    _diversityController.text = '${config.diversityWindowDays}';
    _dietaryNotesController.text = config.dietaryNotes;
    setState(() => _mealPlanConfig = config);
  }

  // Mirrors _onApiKeyChanged: the model update (setState) happens
  // immediately so the UI stays responsive, but the SharedPreferences write
  // is debounced so a burst of edits (typing, or several field changes in
  // quick succession) collapses into one round trip.
  void _saveMealPlanConfig(MealPlanConfig updated) {
    setState(() => _mealPlanConfig = updated);
    _mealPlanSaveDebounce?.cancel();
    _mealPlanSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => widget.mealPlanConfigRepository.save(updated),
    );
  }

  void _onPortionsChanged(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(portionsPerMeal: parsed));
  }

  void _onDiversityChanged(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0) return;
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(diversityWindowDays: parsed));
  }

  void _onDietaryNotesChanged(String value) {
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(dietaryNotes: value));
  }

  void _addMealSlot() {
    final slots = [
      ..._mealPlanConfig!.mealSlots,
      MealSlot(id: '${DateTime.now().millisecondsSinceEpoch}', mealType: MealType.lunch, protein: 'meat', count: 1),
    ];
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(mealSlots: slots));
  }

  void _updateMealSlot(int index, MealSlot slot) {
    final slots = [..._mealPlanConfig!.mealSlots];
    slots[index] = slot;
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(mealSlots: slots));
  }

  Future<void> _removeMealSlot(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Remove this meal slot?',
      content: 'This removes the meal slot from your weekly plan.',
    );
    if (!confirmed || !mounted) return;
    final slots = [..._mealPlanConfig!.mealSlots]..removeAt(index);
    _saveMealPlanConfig(_mealPlanConfig!.copyWith(mealSlots: slots));
  }

  Future<void> _openModelEditor({String? existing, int? index}) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ModelEditorDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _models!.add(result);
      } else {
        _models![index] = result;
      }
    });
    await widget.aiConfigRepository.saveModels(_models!);
  }

  Future<void> _removeModel(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Delete this model?',
      content: 'This removes ${_models![index]} from the list.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _models!.removeAt(index));
    await widget.aiConfigRepository.saveModels(_models!);
  }

  // Only called from the move-up/move-down buttons, which are disabled at
  // the top/bottom of the list, so index + delta is always in range here.
  Future<void> _moveModel(int index, int delta) async {
    setState(() {
      final entry = _models!.removeAt(index);
      _models!.insert(index + delta, entry);
    });
    await widget.aiConfigRepository.saveModels(_models!);
  }

  Future<void> _openGroundingModelEditor({String? existing, int? index}) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ModelEditorDialog(existing: existing),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _groundingModels!.add(result);
      } else {
        _groundingModels![index] = result;
      }
    });
    await widget.aiConfigRepository.saveGroundingModels(_groundingModels!);
  }

  Future<void> _removeGroundingModel(int index) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Delete this grounding model?',
      content: 'This removes ${_groundingModels![index]} from the list.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _groundingModels!.removeAt(index));
    await widget.aiConfigRepository.saveGroundingModels(_groundingModels!);
  }

  // Only called from the move-up/move-down buttons, which are disabled at
  // the top/bottom of the list, so index + delta is always in range here.
  Future<void> _moveGroundingModel(int index, int delta) async {
    setState(() {
      final entry = _groundingModels!.removeAt(index);
      _groundingModels!.insert(index + delta, entry);
    });
    await widget.aiConfigRepository.saveGroundingModels(_groundingModels!);
  }

  Future<void> _openEditor({StoreConfig? existing}) async {
    // Deal items are matched back to a store by display name (see
    // planif_screen._retryStore), so two stores sharing a name would
    // silently corrupt each other's results on retry - block that instead
    // of letting it happen.
    final otherNames = _stores!
        .where((s) => s.id != existing?.id)
        .map((s) => s.name.trim().toLowerCase())
        .toSet();
    final result = await showDialog<StoreConfig>(
      context: context,
      builder: (_) => _StoreEditorDialog(existing: existing, otherNames: otherNames),
    );
    if (result == null) return;
    setState(() {
      final index = _stores!.indexWhere((s) => s.id == result.id);
      if (index == -1) {
        _stores!.add(result);
      } else {
        _stores![index] = result;
      }
    });
    await widget.repository.save(_stores!);
  }

  Future<void> _remove(StoreConfig store) async {
    final confirmed = await confirmDelete(
      context,
      title: 'Delete this store?',
      content: 'This removes ${store.name} and its flyer link.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _stores!.removeWhere((s) => s.id == store.id));
    await widget.repository.save(_stores!);
  }

  @override
  Widget build(BuildContext context) {
    final stores = _stores;
    final models = _models;
    final groundingModels = _groundingModels;
    final mealPlanConfig = _mealPlanConfig;
    return Scaffold(
      appBar: AppBar(title: const Text('Config')),
      // Each settings section gets its own Card so the page reads as a set
      // of distinct, scannable groups instead of one continuous scroll with
      // nothing but thin dividers between sections (issue #31).
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _SectionCard(
            icon: Icons.storefront_outlined,
            title: 'Stores',
            trailing: IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add store',
              onPressed: stores == null ? null : () => _openEditor(),
            ),
            child: stores == null
                ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                : stores.isEmpty
                ? const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No stores configured yet.')))
                : Column(
                    children: [
                      for (final store in stores)
                        ListTile(
                          title: Text(store.name),
                          subtitle: Text(store.flyerUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => _openEditor(existing: store),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _remove(store),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            icon: Icons.restaurant_menu_outlined,
            title: 'Meal plan',
            trailing: IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add meal slot',
              onPressed: mealPlanConfig == null ? null : _addMealSlot,
            ),
            child: mealPlanConfig == null
                ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _portionsController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Portions per meal'),
                                onChanged: _onPortionsChanged,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: _diversityController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Diversity window (days)'),
                                onChanged: _onDiversityChanged,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: TextField(
                          controller: _dietaryNotesController,
                          maxLines: null,
                          minLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Additional planning instructions',
                            hintText: 'e.g. no more than 2 days of fish per week, no red meat',
                          ),
                          onChanged: _onDietaryNotesChanged,
                        ),
                      ),
                      for (var i = 0; i < mealPlanConfig.mealSlots.length; i++) ...[
                        Builder(
                          builder: (context) {
                            final slot = mealPlanConfig.mealSlots[i];
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: DropdownButtonFormField<MealType>(
                                      key: ValueKey('meal-type-${slot.id}'),
                                      initialValue: slot.mealType,
                                      decoration: const InputDecoration(labelText: 'Meal'),
                                      items: MealType.values
                                          .map((t) => DropdownMenuItem(value: t, child: Text(t.name)))
                                          .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        _updateMealSlot(i, slot.copyWith(mealType: value));
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 2,
                                    child: TextFormField(
                                      key: ValueKey('protein-${slot.id}'),
                                      initialValue: slot.protein,
                                      decoration: const InputDecoration(labelText: 'Protein'),
                                      onChanged: (value) {
                                        final trimmed = value.trim();
                                        if (trimmed.isEmpty) return;
                                        _updateMealSlot(i, slot.copyWith(protein: trimmed));
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      key: ValueKey('count-${slot.id}'),
                                      initialValue: '${slot.count}',
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'Count'),
                                      onChanged: (value) {
                                        final parsed = int.tryParse(value);
                                        if (parsed == null || parsed < 0) return;
                                        _updateMealSlot(i, slot.copyWith(count: parsed));
                                      },
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Remove meal slot',
                                    onPressed: mealPlanConfig.mealSlots.length == 1
                                        ? null
                                        : () => _removeMealSlot(i),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${mealPlanConfig.mealsPerWeek} meals / week',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            icon: Icons.smart_toy_outlined,
            title: 'AI',
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _apiKeyController,
                    obscureText: _obscureApiKey,
                    decoration: InputDecoration(
                      labelText: 'Google AI API key',
                      helperText: 'Stored on this device only.',
                      suffixIcon: IconButton(
                        icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off),
                        tooltip: _obscureApiKey ? 'Show key' : 'Hide key',
                        onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                      ),
                    ),
                    onChanged: _onApiKeyChanged,
                  ),
                ),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Divider(height: 24)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Models (tried in order)', style: Theme.of(context).textTheme.titleSmall),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: 'Add model',
                        onPressed: models == null ? null : () => _openModelEditor(),
                      ),
                    ],
                  ),
                ),
                if (models != null)
                  Column(
                    children: [
                      for (var i = 0; i < models.length; i++)
                        ListTile(
                          dense: true,
                          title: Text(models[i]),
                          onTap: () => _openModelEditor(existing: models[i], index: i),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_upward),
                                tooltip: 'Move up',
                                visualDensity: VisualDensity.compact,
                                onPressed: i == 0 ? null : () => _moveModel(i, -1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.arrow_downward),
                                tooltip: 'Move down',
                                visualDensity: VisualDensity.compact,
                                onPressed: i == models.length - 1 ? null : () => _moveModel(i, 1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Remove model',
                                visualDensity: VisualDensity.compact,
                                // At least one model must stay configured.
                                onPressed: models.length == 1 ? null : () => _removeModel(i),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Divider(height: 24)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Grounding search models (tried in order)',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: 'Add grounding model',
                        onPressed: groundingModels == null ? null : () => _openGroundingModelEditor(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    "Used for the full-plan step's recipe-link search - keep this to models that actually carry a "
                    'Search grounding quota on your API key, which can be a narrower set than the models above.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (groundingModels != null)
                  Column(
                    children: [
                      for (var i = 0; i < groundingModels.length; i++)
                        ListTile(
                          dense: true,
                          title: Text(groundingModels[i]),
                          onTap: () => _openGroundingModelEditor(existing: groundingModels[i], index: i),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_upward),
                                tooltip: 'Move grounding model up',
                                visualDensity: VisualDensity.compact,
                                onPressed: i == 0 ? null : () => _moveGroundingModel(i, -1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.arrow_downward),
                                tooltip: 'Move grounding model down',
                                visualDensity: VisualDensity.compact,
                                onPressed: i == groundingModels.length - 1
                                    ? null
                                    : () => _moveGroundingModel(i, 1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Remove grounding model',
                                visualDensity: VisualDensity.compact,
                                // At least one grounding model must stay configured.
                                onPressed: groundingModels.length == 1 ? null : () => _removeGroundingModel(i),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Divider(height: 24)),
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('AI usage log'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiUsageScreen()));
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled, icon-led card used to visually separate one settings section
/// (Stores / Meal plan / AI) from the next - see issue #31: the previous
/// layout separated sections with a single-line header and a thin divider,
/// which made a fully configured settings page read as one undifferentiated
/// wall rather than a set of distinct groups. Collapsible so a long section
/// (e.g. Models with many entries) can be tucked away while working in
/// another one.
///
/// Kept as its own State rather than lifting `_expanded` into
/// _ConfigScreenState: the parent's build() runs on every keystroke/reload
/// across the whole screen (API key typing, meal plan edits, model list
/// loads), and this widget occupies the same position in that rebuilt list
/// every time, so Flutter preserves this State - and therefore the
/// collapsed/expanded choice - across those parent rebuilds for free.
class _SectionCard extends StatefulWidget {
  const _SectionCard({required this.icon, required this.title, required this.child, this.trailing});

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  State<_SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<_SectionCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Icon(widget.icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium)),
                ?widget.trailing,
                IconButton(
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  tooltip: _expanded ? 'Collapse ${widget.title}' : 'Expand ${widget.title}',
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
          ),
          if (_expanded) ...[widget.child, const SizedBox(height: 8)],
        ],
      ),
    );
  }
}

class _StoreEditorDialog extends StatefulWidget {
  const _StoreEditorDialog({this.existing, this.otherNames = const {}});

  final StoreConfig? existing;

  /// Every other configured store's name, trimmed and lowercased. Used to
  /// reject a duplicate name - see the comment in ConfigScreen._openEditor.
  final Set<String> otherNames;

  @override
  State<_StoreEditorDialog> createState() => _StoreEditorDialogState();
}

class _StoreEditorDialogState extends State<_StoreEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _urlController = TextEditingController(text: widget.existing?.flyerUrl ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Add store' : 'Edit store'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Display name'),
              validator: (v) {
                final trimmed = v?.trim() ?? '';
                if (trimmed.isEmpty) return 'Required';
                if (widget.otherNames.contains(trimmed.toLowerCase())) {
                  return 'A store with this name already exists';
                }
                return null;
              },
            ),
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Flyer URL', hintText: 'https://...'),
              keyboardType: TextInputType.url,
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return 'Required';
                final uri = Uri.tryParse(value);
                if (uri == null || !uri.isAbsolute) return 'Enter a valid URL';
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final id = widget.existing?.id ?? '${DateTime.now().millisecondsSinceEpoch}';
            Navigator.of(context).pop(
              StoreConfig(id: id, name: _nameController.text.trim(), flyerUrl: _urlController.text.trim()),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ModelEditorDialog extends StatefulWidget {
  const _ModelEditorDialog({this.existing});

  final String? existing;

  @override
  State<_ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _ModelEditorDialogState extends State<_ModelEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _modelController;

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(text: widget.existing ?? '');
  }

  @override
  void dispose() {
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Add model' : 'Edit model'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _modelController,
          decoration: const InputDecoration(labelText: 'Model id', hintText: 'gemini-3.5-flash-lite'),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(_modelController.text.trim());
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
