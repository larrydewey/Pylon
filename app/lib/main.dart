import 'package:flutter/material.dart';

import 'backend/select.dart';
import 'theme.dart';
import 'ui/app_state.dart';
import 'ui/hosts_page.dart';
import 'ui/sessions_page.dart';
import 'ui/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final st = AppState(await makeBackend());
  runApp(PylonApp(st: st));
  await st.load();
}

class PylonApp extends StatelessWidget {
  const PylonApp({super.key, required this.st});
  final AppState st;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pylon',
        debugShowCheckedModeBanner: false,
        theme: pylonTheme(),
        home: Home(st: st),
      );
}

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
