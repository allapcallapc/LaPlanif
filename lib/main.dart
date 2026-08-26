import 'package:flutter/material.dart';

import 'screens/config_screen.dart';
import 'screens/history_screen.dart';
import 'screens/planif_screen.dart';
import 'services/ai_config_repository.dart';
import 'services/ai_deal_extraction_service.dart';
import 'services/flyer_scraper_service.dart';
import 'services/meal_history_repository.dart';
import 'services/store_config_repository.dart';

void main() {
  runApp(const LaPlanifApp());
}

class LaPlanifApp extends StatelessWidget {
  const LaPlanifApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LaPlanif',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7A2E4D)),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // Constructed once for the app's lifetime rather than in build(), which
  // IndexedStack calls on every rebuild (not just tab switches) - each of
  // these owns an http.Client, and building fresh ones every rebuild would
  // leak the previous client without ever calling .close() on it.
  final StoreConfigRepository _storeRepository = StoreConfigRepository();
  final AiConfigRepository _aiConfigRepository = AiConfigRepository();
  final FlyerScraperService _scraperService = FlyerScraperService();
  final AiDealExtractionService _extractionService = AiDealExtractionService();
  final MealHistoryRepository _mealHistoryRepository = MealHistoryRepository();
  int _tabIndex = 0;

  // IndexedStack (below) deliberately keeps every tab's State alive across
  // switches - e.g. Planif needs to keep an in-progress fetch/preview when
  // the user tabs away and back. History is the exception: it only loads
  // its list once, in initState, so without this it would keep showing
  // whatever it saw on the very first build (typically empty) even after a
  // plan gets saved from Planif. Bumping this on every switch INTO History
  // changes HistoryScreen's key, which makes Flutter tear down and recreate
  // its State - re-running initState's load - without affecting the other
  // tabs' persisted state.
  int _historyReloadTick = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      PlanifScreen(
        repository: _storeRepository,
        scraperService: _scraperService,
        extractionService: _extractionService,
        aiConfigRepository: _aiConfigRepository,
        mealHistoryRepository: _mealHistoryRepository,
      ),
      HistoryScreen(key: ValueKey(_historyReloadTick), repository: _mealHistoryRepository),
      ConfigScreen(repository: _storeRepository, aiConfigRepository: _aiConfigRepository),
    ];
    return Scaffold(
      // Keyed because DropdownButtonFormField (used in ConfigScreen's meal
      // plan rows) renders its own internal IndexedStack per instance, so a
      // bare find.byType(IndexedStack) in tests would match more than this
      // one once there's more than one meal slot.
      body: IndexedStack(key: const Key('home_tab_stack'), index: _tabIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() {
          _tabIndex = i;
          if (i == 1) _historyReloadTick++;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            selectedIcon: Icon(Icons.checklist),
            label: 'Planif',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Config',
          ),
        ],
      ),
    );
  }
}
