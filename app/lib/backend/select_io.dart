import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'demo_backend.dart';
import 'frames.dart';
import 'model.dart';
import 'process_backend.dart';

const platform = MethodChannel('pylon/platform');

/// The core's binaries. Android: libpylon.so and libpylon_term.so in the
/// native library directory, the pylond builds and their signed release
/// unpacked from the app's assets, PYLON_HOME in the app's private files,
/// the local shell in the isolated service (libpylon_local.so there), and
/// the active network's DNS servers, since Android has no /etc/resolv.conf.
/// Desktop: PYLON_BIN_DIR, else beside this executable, and PYLON_HOME as the command-line client
/// uses it. With PYLON_DEMO=1, or no core found, the demo backend (which
/// says so on every screen).
Future<Backend> makeBackend() async {
  if (Platform.isAndroid) {
    final p = Map<String, String>.from(await platform.invokeMethod('paths') as Map);
    final bin = p['bin']!, files = p['files']!;
    final pylond = '$files/pylond';
    await Directory(pylond).create(recursive: true);
    // The builds and their signed release (SPEC 8.2); pylon checks the
    // release before it pushes a build, and refuses without one.
    for (final name in ['pylond-x86_64', 'pylond-aarch64', 'pylond.release', 'pylond.proof']) {
      final f = File('$pylond/$name');
      Uint8List? bytes;
      try {
        final data = await rootBundle.load('assets/pylond/$name');
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        bytes = null; // not in this build (an unsigned developer build)
      }
      if (bytes == null) {
        if (await f.exists()) await f.delete();
        continue;
      }
      await f.writeAsBytes(bytes, flush: true);
    }
    return ProcessBackend.at('$bin/libpylon.so', '$bin/libpylon_term.so', pylond, '$files/pylon',
        agent: (conn, req) async => await platform.invokeMethod<Uint8List>('agent', {'conn': conn, 'request': req}),
        agentClose: (conn) => platform.invokeMethod('agentClose', conn),
        localConduit: ServiceConduit.start,
        resolvConf: () => platform.invokeMethod<String>('resolvConf'));
  }
  final env = Platform.environment;
  if (env['PYLON_DEMO'] == '1') return DemoBackend();
  final bin = env['PYLON_BIN_DIR'] ?? File(Platform.resolvedExecutable).parent.path;
  final home = env['PYLON_HOME'] ?? '${env['HOME'] ?? '.'}/.config/pylon';
  if (!File('$bin/pylon').existsSync() || !File('$bin/pylon-term').existsSync()) return DemoBackend();
  return ProcessBackend(bin, home);
}

/// Keeps terminal content out of screenshots and recents (Android).
Future<void> setSecure(bool on) async {
  if (Platform.isAndroid) await platform.invokeMethod('secure', on);
}

/// Tabs and splits (SPEC 15, Linux desktop); phones and tablets get the
/// one-terminal layout (PYLON_LAYOUT=phone: the phone layout anywhere).
bool get desktopLayout => (Platform.isLinux || Platform.isMacOS || Platform.isWindows) && Platform.environment['PYLON_LAYOUT'] != 'phone';

/// Opens Symbolon at its SSH keys (Android), the app that holds the keys;
/// false where there is no such app or it could not be opened.
Future<bool> openKeyHolder() async {
  if (!Platform.isAndroid) return false;
  return await platform.invokeMethod<bool>('openSymbolonKeys') ?? false;
}

/// Android: while [live] connections are open, a foreground service keeps
/// Pylon's network, which the system takes from an app that is not in
/// front (Symbolon's consent sheet, or any other app). 0 ends it.
Future<void> keepConnections(int live) async {
  if (Platform.isAndroid) await platform.invokeMethod('connections', live);
}

/// Where signatures come from, for the desktop's title bar.
String get agentNote => Platform.isAndroid ? 'Symbolon' : (Platform.environment['SSH_AUTH_SOCK'] != null ? 'Agent at SSH_AUTH_SOCK' : 'No agent (SSH_AUTH_SOCK unset)');

/// What "this device" is called in the interface.
String get deviceName => Platform.isAndroid || Platform.isIOS ? 'this phone' : 'this computer';

/// The local shell on Android (SPEC 13): `libpylon_local.so --android`
/// run by LocalShellService, an isolatedProcess service (a UID of its own,
/// no permissions, no storage, no network), over a socket pair the
/// activity holds. The service frames the launcher's error output as type
/// 7, which arrives here as [messages].
class ServiceConduit implements Conduit {
  ServiceConduit._(this._id);
  final int _id;
  final _out = StreamController<List<int>>();
  final _msgs = StreamController<String>();
  final _exit = Completer<int>();
  final _reader = FrameReader();

  static const _events = EventChannel('pylon/local');
  static final Map<int, ServiceConduit> _open = {};
  static StreamSubscription<dynamic>? _sub;

  static Future<Conduit> start(int rows, int cols) async {
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      final c = _open[m['id'] as int];
      if (c == null) return;
      final data = m['data'];
      if (data is Uint8List) c._got(data);
      if (m['end'] == true) c._ended();
    });
    final id = await platform.invokeMethod<int>('localStart', {'rows': rows, 'cols': cols});
    if (id == null) throw StateError('the local shell service did not start');
    return _open[id] = ServiceConduit._(id);
  }

  void _got(Uint8List d) {
    for (final (t, p) in _reader.add(d)) {
      if (t == 7) {
        _msgs.add(String.fromCharCodes(p));
      } else {
        _out.add(frame(t, p));
      }
    }
  }

  void _ended() {
    _open.remove(_id);
    if (!_exit.isCompleted) _exit.complete(255); // frame 5 carries the real status
    _out.close();
    _msgs.close();
  }

  @override
  Stream<List<int>> get output => _out.stream;
  @override
  Stream<String> get messages => _msgs.stream;
  @override
  void add(List<int> f) => platform.invokeMethod('localInput', {'id': _id, 'data': Uint8List.fromList(f)});
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void close() => platform.invokeMethod('localClose', _id);
}
