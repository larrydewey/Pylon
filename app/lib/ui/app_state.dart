import 'package:flutter/foundation.dart';

import '../backend/model.dart';

/// Hosts, pins and live sessions, shared by every page.
class AppState extends ChangeNotifier {
  AppState(this.backend);
  final Backend backend;
  List<Host> hosts = [];
  List<Pin> pinList = [];
  final Map<Host, Session> sessions = {};
  bool obfuscateKeys = true;
  bool blockScreenshots = true;

  Future<void> load() async {
    hosts = await backend.loadHosts();
    pinList = await backend.pins();
    notifyListeners();
  }

  Future<void> refreshPins() async {
    pinList = await backend.pins();
    notifyListeners();
  }

  Future<void> save() async {
    await backend.saveHosts(hosts);
    notifyListeners();
  }

  Pin? pinFor(Host h) {
    final t = '${h.address.toLowerCase()}:${h.port}';
    for (final p in pinList) {
      if (p.token == t) return p;
    }
    return null;
  }

  Session? sessionFor(Host h) {
    final s = sessions[h];
    return (s != null && s.exitCode == null) ? s : null;
  }

  Session open(Host h, int rows, int cols) {
    final live = sessionFor(h);
    if (live != null) return live;
    final s = backend.open(h, rows, cols);
    sessions[h] = s;
    s.changes.listen((_) => notifyListeners());
    return s;
  }
}
