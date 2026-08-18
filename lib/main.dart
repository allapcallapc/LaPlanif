import 'package:flutter/material.dart';

import 'screens/deals_screen.dart';
import 'screens/store_config_screen.dart';
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
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
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
  final StoreConfigRepository _storeRepository = StoreConfigRepository();
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      StoreConfigScreen(repository: _storeRepository),
      DealsScreen(repository: _storeRepository),
    ];
    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            selectedIcon: Icon(Icons.storefront),
            label: 'Stores',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_offer_outlined),
            selectedIcon: Icon(Icons.local_offer),
            label: 'Deals',
          ),
        ],
      ),
    );
  }
}
