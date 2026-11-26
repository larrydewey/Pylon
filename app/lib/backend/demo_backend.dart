import 'dart:async';
import 'dart:typed_data';

import '../term/screen.dart';
import 'access.dart';
import 'files.dart';
import 'mem_files.dart';
import 'model.dart';

/// A backend with no core behind it, for previewing the interface (the
/// web build). It says so on every screen it draws.
class DemoBackend implements Backend {
  final _hosts = [
    Host(name: 'build-01', user: 'alice', address: '10.0.8.21', mode: Mode.pylon),
    Host(name: 'pi-garage', user: 'pi', address: '192.168.1.40'),
    Host(name: 'prod-db', user: 'ops', address: '10.0.4.12', jump: 'ops@bastion.example.org', tag: 'production'),
    Host(name: 'new-vps', user: 'root', address: '203.0.113.7'),
  ];

  @override
  bool get demo => true;

  @override
  Future<List<Host>> loadHosts() async => _hosts;

  @override
  Future<void> saveHosts(List<Host> hosts) async {}

  @override
  Future<List<Pin>> pins() async => [
        Pin('10.0.8.21:22', 'ssh-ed25519', 'SHA256:3fQkV0Zr9dWz9c', '2026-11-02', 'laptop'),
        Pin('192.168.1.40:22', 'ssh-ed25519', 'SHA256:9xQe2LkVb7Wq1A', '2026-10-14', 'phone'),
        Pin('10.0.4.12:22', 'ecdsa-sha2-nistp256', 'SHA256:Lm2aP0pRtYv81k', '2026-03-14', 'laptop'),
      ];

  @override
  Future<Outcome> pin(Host h, String fingerprint) async => Outcome(false, 'Demo mode: nothing is pinned.');

  @override
  Future<Outcome> trustCa(String pattern, String key) async => Outcome(false, 'Demo mode: no CA is trusted.');

  @override
  Session open(Host h, int rows, int cols, {int? attach}) => _DemoSession(h, rows, cols);

  @override
  FileSession openFiles(Host h) => MemFiles(h);

  @override
  Authorize authorize(Host h, List<String> keys, {bool ca = false}) => _DemoAuthorize(h, keys, ca);

  @override
  bool get hasLocalShell => true;

  @override
  Session openLocal(int rows, int cols, {bool shareNet = false}) => _DemoSession(Host.local(), rows, cols);
}

class _DemoSession extends Session {
  _DemoSession(super.host, int rows, int cols) {
    _draw(rows, cols);
  }

  late final _lines = host.local ? _localLines : _hostLines;

  static const _localLines = <String>[
    'Demo mode: no shell runs in this preview.',
    '',
    '~ local \$ ssh build-01',
    'ssh: no keys here. Use Pylon to connect.',
    '~ local \$ ',
  ];

  static const _hostLines = <String>[
    'Demo mode: no connection is made in this preview.',
    '',
    'alice@build-01:~/src/pylon\$ make test',
    'ok   pylon protocol: SSH closed after the bootstrap',
    'ok   pylon protocol: a terminal that roams mid-session',
    'ok   pylon protocol: re-attach from a new client',
    '90 passed, 0 failed',
    'alice@build-01:~/src/pylon\$ ',
  ];

  void _draw(int rows, int cols) {
    final n = rows * cols;
    final cp = Uint32List(n)..fillRange(0, n, 32);
    final attr = Uint32List(n)..fillRange(0, n, Screen.attrDefault);
    for (var y = 0; y < _lines.length && y < rows; y++) {
      final l = _lines[y];
      for (var x = 0; x < l.length && x < cols; x++) {
        cp[y * cols + x] = l.codeUnitAt(x);
        if (l.startsWith('ok') && x < 2) attr[y * cols + x] = 6 | (256 << 9);
        if (l.startsWith('alice') && x < 14) attr[y * cols + x] = 6 | (256 << 9) | (1 << 18);
        if (l.startsWith('~ local') && x < 7) attr[y * cols + x] = 13 | (256 << 9);
      }
    }
    final last = _lines.length - 1;
    screen = Screen(rows, cols, _lines[last].length, last, 3, cp, attr);
    changed();
  }

  @override
  void input(List<int> bytes) {}

  @override
  void resize(int rows, int cols) => _draw(rows, cols);

  @override
  void close() {}
}

/// What `pylon authorize` would report, said to be a demo first.
class _DemoAuthorize extends Authorize {
  _DemoAuthorize(super.host, super.keys, bool ca) : super(ca: ca) {
    _timer = Timer(const Duration(milliseconds: 600), _run);
  }

  Timer? _timer;

  void _run() {
    lines.add(const ReportLine(ReportKind.warning, 'Demo mode: no connection is made and nothing is installed.'));
    final shown = keys.isEmpty ? ['ecdsa-sha2-nistp256 AAAA symbolon-pylon'] : keys;
    for (final k in shown) {
      final w = k.split(' ');
      lines.add(ReportLine(ReportKind.added, '${w[0]} SHA256:demo${w.length > 2 ? ' ${w[2]}' : ''}'));
    }
    lines.add(const ReportLine(ReportKind.fixed, '~/.ssh/authorized_keys was writable by others; now 600'));
    lines.add(const ReportLine(ReportKind.done, ''));
    ok = true;
    changed();
  }

  @override
  void close() {
    _timer?.cancel();
    if (ok != null) return;
    ok = false;
    messages = 'Stopped.';
    changed();
  }
}
