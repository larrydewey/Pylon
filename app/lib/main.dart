import 'package:material_ui/material_ui.dart';

import 'backend/select.dart';
import 'desktop/desktop_shell.dart';
import 'theme.dart';
import 'ui/app_state.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final st = AppState(await makeBackend());
  runApp(PylonApp(st: st, desktop: desktopLayout));
  await st.load();
}

class PylonApp extends StatelessWidget {
  const PylonApp({super.key, required this.st, this.desktop = false});
  final AppState st;

  /// Tabs and splits (Linux desktop) instead of one terminal at a time.
  final bool desktop;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pylon',
        debugShowCheckedModeBanner: false,
        theme: pylonTheme(),
        home: desktop ? DesktopShell(st: st) : Home(st: st),
      );
}
