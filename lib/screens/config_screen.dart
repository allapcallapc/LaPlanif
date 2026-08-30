import 'package:flutter/material.dart';

import '../services/ai_config_repository.dart';
import '../services/meal_plan_config_repository.dart';
import '../services/store_config_repository.dart';
import 'config_ai_screen.dart';
import 'config_meal_plan_screen.dart';
import 'config_stores_screen.dart';

/// Top-level settings menu - the common settings-app pattern of a short
/// list of rows that each drill down into their own screen (see issue #31:
/// a single screen combining Stores, Meal plan, and AI became an
/// undifferentiated wall once each section held a realistic amount of
/// data). Deliberately stateless: each destination screen owns and loads
/// its own repository data, the same way AiUsageScreen already does.
class ConfigScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Config')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: const Text('Stores'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => ConfigStoresScreen(repository: repository))),
          ),
          ListTile(
            leading: const Icon(Icons.restaurant_menu_outlined),
            title: const Text('Meal plan'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => ConfigMealPlanScreen(repository: mealPlanConfigRepository))),
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('AI'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => ConfigAiScreen(repository: aiConfigRepository))),
          ),
        ],
      ),
    );
  }
}
