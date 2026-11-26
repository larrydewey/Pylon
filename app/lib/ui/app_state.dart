import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/files.dart';
import '../backend/model.dart';
import '../backend/select.dart';

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

  /// Paths cut or copied on the Files page, for a paste on the same host.
  FileClip? clip;

  void setClip(FileClip? c) {
    clip = c;
    notifyListeners();
  }

  // Open file browsers, counted with live connections (Android's
  // foreground service: the document picker puts Pylon in the background).
  int _filesOpen = 0;

  FileSession openFiles(Host h) {
    final f = backend.openFiles(h);
    _filesOpen++;
    _report();
    return f;
  }

  void closeFiles(FileSession f) {
    f.close();
    _filesOpen--;
    _report();
  }

  // `pylon authorize` runs, counted with the connections as well: one
  // waits on Symbolon's consent sheet, with Pylon in the background.
  int _authorizing = 0;

  Authorize authorize(Host h, List<String> keys, {bool ca = false}) {
    final a = backend.authorize(h, keys, ca: ca);
    _authorizing++;
    _report();
    var counted = true;
    late final StreamSubscription<void> sub;
    sub = a.changes.listen((_) {
      if (a.ok == null || !counted) return;
      counted = false;
      _authorizing--;
      _report();
      sub.cancel();
    });
    return a;
  }

  /// Every pinned key of [h] (a host may have several, one per type).
  List<Pin> pinsFor(Host h) {
    final t = '${h.address.toLowerCase()}:${h.port}';
    return [for (final p in pinList) if (p.token == t) p];
  }

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

  /// Sessions that ended (the host hung up, or they failed) and are kept
  /// to show how, until removed.
  List<Session> get ended => [for (final s in sessions) if (s.exitCode != null) s];

  /// Forgets every ended session.
  void clearEnded() {
    for (final s in ended) {
      s.close();
      sessions.remove(s);
    }
    _report();
    notifyListeners();
  }

  /// The live session for a host (the first, when the desktop layout
  /// opened several); for the local shell, the live local shell.
  Session? sessionFor(Host h) {
    for (final s in sessions) {
      if (s.exitCode == null && (identical(s.host, h) || (h.local && s.local))) return s;
    }
    return null;
  }

  /// The host's live session, or a new one (the phone layout: one per
  /// host); after [reconnect], one that picks up the kept shell.
  Session open(Host h, int rows, int cols) => sessionFor(h) ?? openNew(h, rows, cols, attach: _pickUp.remove(h));

  // Hosts whose next session picks up a shell pylond kept (by its id).
  final Map<Host, int> _pickUp = {};

  /// Forgets the ended session [s] so that its host's next [open]
  /// connects again: to the same shell, when only the link was lost.
  void reconnect(Session s) {
    final k = s.resumable ? s.keptSession : null;
    end(s);
    if (k != null) _pickUp[s.host] = k;
  }

  /// Always a new session (the desktop layout: a pane each); [attach]
  /// picks up a shell pylond kept.
  Session openNew(Host h, int rows, int cols, {int? attach}) {
    final s = h.local ? backend.openLocal(rows, cols, shareNet: localShareNet) : backend.open(h, rows, cols, attach: attach);
    sessions.add(s);
    // Pages that list sessions show their title, status and how they
    // ended; a new screen alone (every keystroke's echo, every line of
    // output) is the terminal's own business and rebuilds nothing else.
    var seen = _seen(s);
    s.changes.listen((_) {
      final now = _seen(s);
      if (now == seen) return;
      seen = now;
      _report();
      notifyListeners();
    });
    _report();
    return s;
  }

  static (int?, String, String, AgentKeys, int, String) _seen(Session s) => (s.exitCode, s.title, s.status, s.agentKeys, s.linkState, s.linkNote);

  /// Ends a session and forgets it.
  void end(Session s) {
    s.close();
    sessions.remove(s);
    _report();
    notifyListeners();
  }

  // Android ends the network of an app that is not in front: the live
  // connections, counted, keep Pylon's foreground service up meanwhile.
  int _reported = 0;
  void _report() {
    final n = [for (final s in live) if (!s.local) s].length + _filesOpen + _authorizing;
    if (n == _reported) return;
    _reported = n;
    keepConnections(n);
  }
}

/// What the Files page's cut or copy marked: canonical paths on one host.
class FileClip {
  FileClip(this.host, this.cut, this.paths);
  final Host host;
  final bool cut;
  final List<Uint8List> paths;
}
