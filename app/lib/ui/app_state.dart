import 'package:flutter/foundation.dart';

import '../backend/model.dart';

/// Hosts, pins and live sessions, shared by every page.
class AppState extends ChangeNotifier {
  AppState(this.backend);
  final Backend backend;
  List<Host> hosts = [];
  List<Pin> pinList = [];

  /// Every session this app started, live or ended, in order.
  final List<Session> sessions = [];
  bool obfuscateKeys = true;
  bool blockScreenshots = true;

  /// Linux: the local shell gets the device's network (off: none).
  bool localShareNet = false;

  /// The desktop layout's way to open a host: in a tab, not a page.
  void Function(Host h)? openInTab;

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

  List<Session> get live => [for (final s in sessions) if (s.exitCode == null) s];

  /// The live session for a host (the first, when the desktop layout
  /// opened several); for the local shell, the live local shell.
  Session? sessionFor(Host h) {
    for (final s in sessions) {
      if (s.exitCode == null && (identical(s.host, h) || (h.local && s.local))) return s;
    }
    return null;
  }

  /// The host's live session, or a new one (the phone layout: one per host).
  Session open(Host h, int rows, int cols) => sessionFor(h) ?? openNew(h, rows, cols);

  /// Always a new session (the desktop layout: a pane each).
  Session openNew(Host h, int rows, int cols) {
    final s = h.local ? backend.openLocal(rows, cols, shareNet: localShareNet) : backend.open(h, rows, cols);
    sessions.add(s);
    s.changes.listen((_) => notifyListeners());
    return s;
  }

  /// Ends a session and forgets it.
  void end(Session s) {
    s.close();
    sessions.remove(s);
    notifyListeners();
  }
}
