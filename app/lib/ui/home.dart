import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_state.dart';
import 'hosts_page.dart';
import 'sessions_page.dart';
import 'settings_page.dart';

/// Hosts, sessions and settings: the phone layout, and on the desktop the
/// "Hosts and settings" page.
class Home extends StatefulWidget {
  const Home({super.key, required this.st});
  final AppState st;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.st,
        builder: (context, _) {
          final pages = [HostsPage(st: widget.st), SessionsPage(st: widget.st), SettingsPage(st: widget.st)];
          return Scaffold(
            body: pages[tab],
            bottomNavigationBar: NavigationBar(
              backgroundColor: P.ink,
              indicatorColor: P.tealDeep,
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Hosts'),
                NavigationDestination(icon: Icon(Icons.terminal), label: 'Sessions'),
                NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
              ],
            ),
          );
        },
      );
}
