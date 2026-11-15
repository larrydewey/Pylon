import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../term/screen.dart';
import 'frames.dart';
import 'model.dart';

/// The real backend: the Resid core as processes. Per terminal, `pylon
/// --app` holds the connection (keys from the agent at SSH_AUTH_SOCK,
/// Symbolon's) and `pylon-term` (confined) turns the host's output into
/// screens. This app only relays bytes between them and draws screens.
class ProcessBackend implements Backend {
  ProcessBackend(this.binDir, this.home);

  /// Where `pylon`, `pylon-term` and `pylond` live.
  final String binDir;

  /// PYLON_HOME: pins, CAs, pin history, and this app's host list.
  final String home;

  String get _pylon => '$binDir/pylon';
  String get _hostsFile => '$home/app_hosts.json';
  Map<String, String> get _env => {'PYLON_HOME': home};

  @override
  bool get demo => false;

  @override
  Future<List<Host>> loadHosts() async {
    final f = File(_hostsFile);
    if (!await f.exists()) return [];
    final j = jsonDecode(await f.readAsString());
    return [for (final h in (j as List)) Host.fromJson(h as Map<String, dynamic>)];
  }

  @override
  Future<void> saveHosts(List<Host> hosts) async {
    await Directory(home).create(recursive: true);
    final tmp = File('$_hostsFile.tmp');
    await tmp.writeAsString(jsonEncode([for (final h in hosts) h.toJson()]));
    await tmp.rename(_hostsFile);
  }

  @override
  Future<List<Pin>> pins() async {
    final r = await Process.run(_pylon, ['pins'], environment: _env);
    final out = <Pin>[];
    for (final l in (r.stdout as String).split('\n')) {
      final f = l.split(' ');
      if (f.length >= 3) out.add(Pin(f[0], f[1], f[2], f.length > 3 ? f[3] : '', f.length > 4 ? f[4] : ''));
    }
    return out;
  }

  @override
  Future<Outcome> pin(Host h, String fingerprint) async {
    final r = await Process.run(_pylon, ['pin', '-p', '${h.port}', h.address, fingerprint], environment: _env);
    return Outcome(r.exitCode == 0, '${r.stdout}${r.stderr}'.trim());
  }

  @override
  Future<Outcome> trustCa(String pattern, String key) async {
    final r = await Process.run(_pylon, ['ca', pattern, key], environment: _env);
    return Outcome(r.exitCode == 0, '${r.stdout}${r.stderr}'.trim());
  }

  @override
  Session open(Host h, int rows, int cols) => _ProcSession(this, h, rows, cols);
}

class _ProcSession extends Session {
  _ProcSession(this.b, Host h, int rows, int cols) : super(h) {
    screen = Screen.blank(rows, cols);
    _start(rows, cols);
  }

  final ProcessBackend b;
  Process? _conn, _term;
  final _fromConn = FrameReader(), _fromTerm = FrameReader();

  Future<void> _start(int rows, int cols) async {
    status = 'Connecting…';
    changed();
    try {
      _term = await Process.start('${b.binDir}/pylon-term', ['$rows', '$cols']);
      final args = ['--app', '-p', '${host.port}', if (host.jump.isNotEmpty) ...['-J', host.jump], if (host.mode == Mode.pylon) ...['--pylond', '${b.binDir}/pylond'], host.target];
      _conn = await Process.start('${b.binDir}/pylon', args, environment: b._env);
    } catch (e) {
      status = 'Cannot start the Pylon core: $e';
      // `this.`: a bare exitCode here is dart:io's (this process's status).
      this.exitCode = 255;
      changed();
      return;
    }
    _term!.stdout.listen(_onTerm);
    _conn!.stdout.listen((d) {
      for (final (t, p) in _fromConn.add(d)) {
        if (t == 1) _term?.stdin.add(frame(1, p));
      }
    });
    // The core's own messages (prompts, refusals) are text for the
    // principal; shown escaped, never interpreted.
    _conn!.stderr.transform(utf8.decoder).listen((s) {
      status = (status.startsWith('Connecting') ? '' : status) + s;
      changed();
    });
    _conn!.exitCode.then((c) {
      this.exitCode = c;
      _term?.stdin.close();
      changed();
    });
    resize(rows, cols);
  }

  void _onTerm(List<int> d) {
    for (final (t, p) in _fromTerm.add(d)) {
      if (t == 1) {
        final s = Screen.decode(p);
        if (s != null) {
          screen = s;
          if (status.startsWith('Connecting')) status = '';
        }
      } else if (t == 2) {
        _conn?.stdin.add(frame(1, p)); // fixed-format replies go back to the host
      } else if (t == 3) {
        title = String.fromCharCodes(p);
      } else if (t == 4) {
        clipboardRequests.add(Uint8List.fromList(p));
      }
    }
    changed();
  }

  @override
  void input(List<int> bytes) => _conn?.stdin.add(frame(1, bytes));

  @override
  void resize(int rows, int cols) {
    final p = [(rows >> 8) & 255, rows & 255, (cols >> 8) & 255, cols & 255];
    _conn?.stdin.add(frame(2, p));
    _term?.stdin.add(frame(2, p));
  }

  @override
  void close() {
    _conn?.kill();
    _term?.kill();
  }
}
