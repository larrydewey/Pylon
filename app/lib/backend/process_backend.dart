import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../term/screen.dart';
import 'frames.dart';
import 'model.dart';

/// Whether this build pushes pylond without its release check (SPEC 8.2):
/// only a developer build, `--dart-define=PYLON_UNVERIFIED_PYLOND=true`.
/// Otherwise pylon refuses a pylond that is not a signed, logged release
/// at least as new as the newest it has accepted.
const unverifiedPylond = bool.fromEnvironment('PYLON_UNVERIFIED_PYLOND');

/// The connection side of one terminal, framed both ways (type (1) |
/// length (4) | payload): `pylon --app` for a host, `pylon-local` for the
/// local shell, or (Android) the local shell in Pylon's isolated service.
/// From it: 1 the host's (or shell's) output, 3 an agent request, 4 ready,
/// 5 the exit status (1 byte); to it: 1 keys, 2 a size, 3 agent replies.
abstract class Conduit {
  Stream<List<int>> get output;

  /// Text from the core for the principal (prompts, refusals).
  Stream<String> get messages;
  void add(List<int> frame);
  Future<int> get exitCode;

  /// Ends it: its input is closed (a confined process that outlived its
  /// parent sees end of input and hangs up) and it is killed.
  void close();
}

class ProcessConduit implements Conduit {
  ProcessConduit(this.p);
  final Process p;
  bool _closed = false;

  @override
  Stream<List<int>> get output => p.stdout;
  @override
  Stream<String> get messages => p.stderr.transform(utf8.decoder);
  @override
  void add(List<int> frame) {
    if (!_closed) p.stdin.add(frame);
  }

  @override
  Future<int> get exitCode => p.exitCode;
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    p.stdin.close().catchError((_) {});
    p.kill();
  }
}

/// The real backend: the Resid core as processes. Per terminal, `pylon
/// --app` holds the connection (keys from the agent at SSH_AUTH_SOCK,
/// Symbolon's) and `pylon-term` (confined) turns the host's output into
/// screens. This app only relays bytes between them and draws screens.
class ProcessBackend implements Backend {
  /// A desktop layout: `pylon`, `pylon-term`, `pylon-local` and `pylond`
  /// side by side.
  ProcessBackend(String binDir, this.home)
      : pylonPath = '$binDir/pylon',
        termPath = '$binDir/pylon-term',
        pylondPath = '$binDir/pylond',
        localPath = '$binDir/pylon-local',
        localConduit = null,
        resolvConf = null;

  /// Explicit paths (Android: the native library directory for the core,
  /// a directory of pylond builds per machine type, and the local shell
  /// through the isolated service, [localConduit]).
  ProcessBackend.at(this.pylonPath, this.termPath, this.pylondPath, this.home, {this.agent, this.agentClose, this.localPath, this.localConduit, this.resolvConf});

  /// Where the core's agent requests go when it has no SSH_AUTH_SOCK
  /// (Android: Symbolon's agent service, SPEC 7.3). Gets a session's
  /// connection number and one agent-protocol message, and returns the
  /// reply message, or null when there is no agent.
  Future<Uint8List?> Function(int conn, Uint8List request)? agent;

  /// Ends a session's agent connection.
  void Function(int conn)? agentClose;

  /// The network's DNS servers and search domains as resolv.conf text, for
  /// a system without /etc/resolv.conf (Android), asked at each start since
  /// the network changes: the core looks names up itself, through
  /// RESID_RESOLV_CONF. Empty or null: the core reads /etc/resolv.conf.
  final Future<String?> Function()? resolvConf;

  int _conns = 0;

  final String pylonPath, termPath;

  /// A pylond binary, or a directory of pylond-x86_64 / pylond-aarch64,
  /// with the signed release beside them (pylond.release, pylond.proof).
  final String pylondPath;

  /// `pylon-local` (Linux): the confined local shell, SPEC 13.
  final String? localPath;

  /// Starts a local shell elsewhere than in a child process (Android: in
  /// the isolated service, under a UID of its own).
  final Future<Conduit> Function(int rows, int cols)? localConduit;

  /// PYLON_HOME: pins, CAs, pin history, and this app's host list.
  final String home;

  String get _pylon => pylonPath;
  String get _hostsFile => '$home/app_hosts.json';
  Future<Map<String, String>> _env() async {
    final conf = await resolvConf?.call();
    return {
      'PYLON_HOME': home,
      if (agent != null) 'PYLON_AGENT': 'app',
      if (conf != null && conf.isNotEmpty) 'RESID_RESOLV_CONF': conf,
    };
  }

  /// pylon-local's environment: nothing of the app's but what it needs
  /// to find the local home and to refuse a layout that would put
  /// Pylon's files or the agent's socket in it. It hands the shell none
  /// of it (env -i).
  Map<String, String> get _localEnv {
    final e = Platform.environment;
    return {
      for (final k in ['HOME', 'SHELL', 'LANG', 'USER', 'SSH_AUTH_SOCK'])
        if (e[k] != null) k: e[k]!,
      'PYLON_HOME': home,
      'PATH': '/usr/bin:/bin',
    };
  }

  @override
  bool get demo => false;

  @override
  bool get hasLocalShell => localConduit != null || (localPath != null && File(localPath!).existsSync());

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
    final r = await Process.run(_pylon, ['pins'], environment: await _env());
    final out = <Pin>[];
    for (final l in (r.stdout as String).split('\n')) {
      final f = l.split(' ');
      if (f.length >= 3) out.add(Pin(f[0], f[1], f[2], f.length > 3 ? f[3] : '', f.length > 4 ? f[4] : ''));
    }
    return out;
  }

  @override
  Future<Outcome> pin(Host h, String fingerprint) async {
    final r = await Process.run(_pylon, ['pin', '-p', '${h.port}', h.address, fingerprint], environment: await _env());
    return Outcome(r.exitCode == 0, '${r.stdout}${r.stderr}'.trim());
  }

  @override
  Future<Outcome> trustCa(String pattern, String key) async {
    final r = await Process.run(_pylon, ['ca', pattern, key], environment: await _env());
    return Outcome(r.exitCode == 0, '${r.stdout}${r.stderr}'.trim());
  }

  @override
  Session open(Host h, int rows, int cols) => ProcSession(this, h, rows, cols, () async {
        final args = ['--app', '-p', '${h.port}', if (h.jump.isNotEmpty) ...['-J', h.jump], if (h.mode == Mode.pylon) ...[if (unverifiedPylond) '--pylond-unverified', '--pylond', pylondPath], h.target];
        return ProcessConduit(await Process.start(pylonPath, args, environment: await _env()));
      });

  @override
  Session openLocal(int rows, int cols, {bool shareNet = false}) => ProcSession(this, Host.local(), rows, cols, () async {
        final lc = localConduit;
        if (lc != null) return lc(rows, cols);
        final p = localPath;
        if (p == null) throw StateError('no local shell on this device');
        return ProcessConduit(await Process.start(p, [if (shareNet) '--share-net', '$rows', '$cols'], environment: _localEnv, includeParentEnvironment: false));
      });
}

/// One terminal: a [Conduit] for the connection (or the local shell) and
/// `pylon-term`, the confined emulator, for its screens.
class ProcSession extends Session {
  ProcSession(this.b, Host h, int rows, int cols, this._connect) : super(h) {
    screen = Screen.blank(rows, cols);
    _start(rows, cols);
  }

  final ProcessBackend b;
  final Future<Conduit> Function() _connect;
  Conduit? _conn;
  Process? _term;
  bool _closed = false;

  // Until the core says the terminal is ready (frame 4) it reads nothing
  // but agent replies: keys and sizes wait here.
  bool _ready = false;
  late final int _agentConn = ++b._conns;
  final List<Uint8List> _held = [];

  // The exit status the conduit reported (frame 5), which wins over its
  // process's: a launcher that confined itself loses its own.
  int? _reported;

  void _toConn(Uint8List f) {
    if (_ready) {
      _conn?.add(f);
    } else {
      _held.add(f);
    }
  }

  final _fromConn = FrameReader(), _fromTerm = FrameReader();

  Future<void> _start(int rows, int cols) async {
    status = local ? 'Starting the local shell…' : 'Connecting…';
    changed();
    try {
      _term = await Process.start(b.termPath, ['$rows', '$cols']);
      _conn = await _connect();
    } catch (e) {
      status = local ? 'Cannot start the local shell: $e' : 'Cannot start the Pylon core: $e';
      // `this.`: a bare exitCode here is dart:io's (this process's status).
      this.exitCode = 255;
      _term?.kill();
      changed();
      return;
    }
    if (_closed) {
      _conn?.close();
      _term?.kill();
      return;
    }
    _term!.stdout.listen(_onTerm);
    _conn!.output.listen((d) {
      for (final (t, p) in _fromConn.add(d)) {
        if (t == 1) {
          _term?.stdin.add(frame(1, p));
        } else if (t == 3 && !local) {
          _agentRequest(Uint8List.fromList(p));
        } else if (t == 4 && !_ready) {
          _ready = true;
          for (final f in _held) {
            _conn?.add(f);
          }
          _held.clear();
        } else if (t == 5 && p.length == 1) {
          _reported = p[0];
        }
      }
    });
    // The core's own messages (prompts, refusals) are text for the
    // principal; shown escaped, never interpreted.
    _conn!.messages.listen((s) {
      status = (_starting ? '' : status) + s;
      changed();
    });
    _conn!.exitCode.then((c) {
      this.exitCode = _reported ?? c;
      _term?.stdin.close().catchError((_) {});
      changed();
    });
    resize(rows, cols);
  }

  bool get _starting => status.startsWith('Connecting') || status.startsWith('Starting');

  Future<void> _agentRequest(Uint8List req) async {
    final a = b.agent;
    // No agent: an empty failure message (SSH_AGENT_FAILURE).
    final reply = a == null ? null : await a(_agentConn, req);
    // A request for the agent's keys (11): an empty answer (12, count 0)
    // or none at all is something the principal fixes in Symbolon.
    if (a != null && req.length >= 5 && req[4] == 11) {
      agentKeys = keysIn(reply);
      changed();
    }
    _conn?.add(frame(3, reply ?? Uint8List.fromList([0, 0, 0, 1, 5])));
  }

  void _onTerm(List<int> d) {
    for (final (t, p) in _fromTerm.add(d)) {
      if (t == 1) {
        final s = Screen.decode(p);
        if (s != null) {
          screen = s;
          if (_starting) status = '';
        }
      } else if (t == 2) {
        _toConn(frame(1, p)); // fixed-format replies go back to the host
      } else if (t == 3) {
        title = String.fromCharCodes(p);
      } else if (t == 4) {
        clipboardRequests.add(Uint8List.fromList(p));
      }
    }
    changed();
  }

  @override
  void input(List<int> bytes) => _toConn(frame(1, bytes));

  @override
  void resize(int rows, int cols) {
    // An ended session's emulator input is closed; the view still lays out.
    if (exitCode != null || _closed) return;
    final p = [(rows >> 8) & 255, rows & 255, (cols >> 8) & 255, cols & 255];
    _toConn(frame(2, p));
    _term?.stdin.add(frame(2, p));
  }

  @override
  void close() {
    _closed = true;
    if (!local) b.agentClose?.call(_agentConn);
    _conn?.close();
    _term?.stdin.close().catchError((_) {});
    _term?.kill();
  }
}

/// What an agent's reply to a key request says: some keys, none, or (no
/// reply, or the failure message) that the agent could not be reached.
AgentKeys keysIn(Uint8List? reply) {
  if (reply == null || reply.length < 9 || reply[4] != 12) return AgentKeys.unreachable;
  final n = (reply[5] << 24) | (reply[6] << 16) | (reply[7] << 8) | reply[8];
  return n == 0 ? AgentKeys.none : AgentKeys.some;
}
