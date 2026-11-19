import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'clip.dart';
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
        termConduit: (rows, cols) => ServiceConduit.start(rows, cols, kind: 'term'),
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

final _clip = ExpiringClipboard();

/// Copies [text] from the terminal (Pylon's own selection, or a program's
/// OSC 52 write the principal allowed) as SPEC 15 asks: on Android marked
/// sensitive and cleared after 60 seconds if still there (MainActivity's
/// "clipCopy"); elsewhere cleared after 60 seconds if still there.
Future<void> copySensitive(String text) async {
  if (Platform.isAndroid) {
    try {
      if (await platform.invokeMethod<bool>('clipCopy', text) == true) return;
    } catch (_) {}
  }
  await _clip.copy(text);
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

  /// [kind] "shell": the local shell (LocalShellService); "term": a
  /// terminal emulator (TermService), each in an isolated process.
  static Future<Conduit> start(int rows, int cols, {String kind = 'shell'}) async {
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      final c = _open[m['id'] as int];
      if (c == null) return;
      final data = m['data'];
      if (data is Uint8List) c._got(data);
      if (m['end'] == true) c._ended();
    });
    final id = await platform.invokeMethod<int>('localStart', {'rows': rows, 'cols': cols, 'kind': kind});
    if (id == null) throw StateError('the isolated service did not start');
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

// ---------------------------------------------------------------------------
// Files on this device (the Files page's downloads and uploads)
// ---------------------------------------------------------------------------

/// Where a download goes: chosen by the principal, never by the server.
abstract class LocalTarget {
  /// What to call it in messages (a file name or path).
  String get label;
  Future<void> write(Uint8List chunk);

  /// Done; when not [ok] a partial file is removed.
  Future<void> finish(bool ok);
}

/// What an upload reads.
abstract class LocalSource {
  String get name;
  int? get size;

  /// The next chunk, or null at the end.
  Future<Uint8List?> read();
  Future<void> close();
}

/// Android: the system's document picker (no storage permission; Pylon
/// sees only the one document the principal picked). Elsewhere the Files
/// page asks for a path ([pathTarget], [pathSource]).
bool get systemPicker => Platform.isAndroid;

/// The picker's "save as" for [name]; null when the principal cancelled.
Future<LocalTarget?> pickTarget(String name) async {
  final r = await platform.invokeMethod<Map>('docCreate', {'name': name});
  if (r == null) return null;
  return _DocTarget(r['id'] as int, r['label'] as String? ?? name);
}

/// The picker's "open"; null when the principal cancelled.
Future<LocalSource?> pickSource() async {
  final r = await platform.invokeMethod<Map>('docOpen');
  if (r == null) return null;
  final size = r['size'] as int?;
  return _DocSource(r['id'] as int, r['name'] as String? ?? 'upload', size != null && size >= 0 ? size : null);
}

class _DocTarget implements LocalTarget {
  _DocTarget(this.id, this.label);
  final int id;
  @override
  final String label;
  @override
  Future<void> write(Uint8List chunk) => platform.invokeMethod('docWrite', {'id': id, 'data': chunk});
  @override
  Future<void> finish(bool ok) => platform.invokeMethod('docClose', {'id': id, 'ok': ok});
}

class _DocSource implements LocalSource {
  _DocSource(this.id, this.name, this.size);
  final int id;
  @override
  final String name;
  @override
  final int? size;
  @override
  Future<Uint8List?> read() async {
    final b = await platform.invokeMethod<Uint8List>('docRead', {'id': id, 'n': 262144});
    return b == null || b.isEmpty ? null : b;
  }

  @override
  Future<void> close() => platform.invokeMethod('docClose', {'id': id, 'ok': true});
}

/// Where downloads are offered by default on a desktop.
String get downloadsDir {
  final home = Platform.environment['HOME'] ?? '.';
  final d = Directory('$home/Downloads');
  return d.existsSync() ? d.path : home;
}

bool localExists(String path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

/// A new file at [path] (a file there is replaced only with [replace]),
/// written beside it and renamed into place when whole.
Future<LocalTarget> pathTarget(String path, {bool replace = false}) async {
  if (!replace && localExists(path)) throw FileSystemException('exists; not replaced', path);
  if (FileSystemEntity.isDirectorySync(path)) throw FileSystemException('is a directory', path);
  final part = File('$path.part');
  final sink = await part.open(mode: FileMode.writeOnly);
  return _PathTarget(path, part, sink);
}

class _PathTarget implements LocalTarget {
  _PathTarget(this.label, this.part, this.f);
  @override
  final String label;
  final File part;
  final RandomAccessFile f;
  @override
  Future<void> write(Uint8List chunk) => f.writeFrom(chunk);
  @override
  Future<void> finish(bool ok) async {
    await f.close();
    if (ok) {
      await part.rename(label);
    } else if (await part.exists()) {
      await part.delete();
    }
  }
}

Future<LocalSource> pathSource(String path) async {
  final f = File(path);
  if (!await f.exists()) throw FileSystemException('not a file', path);
  final raf = await f.open();
  return _PathSource(f.uri.pathSegments.isEmpty ? path : f.uri.pathSegments.last, await raf.length(), raf);
}

class _PathSource implements LocalSource {
  _PathSource(this.name, this.size, this.f);
  @override
  final String name;
  @override
  final int? size;
  final RandomAccessFile f;
  @override
  Future<Uint8List?> read() async {
    final b = await f.read(262144);
    return b.isEmpty ? null : b;
  }

  @override
  Future<void> close() => f.close();
}
