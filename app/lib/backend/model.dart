import 'dart:async';
import 'dart:typed_data';

import '../term/screen.dart';
import 'files.dart';

enum Mode { ssh, pylon }

class Host {
  Host({required this.name, required this.user, required this.address, this.port = 22, this.mode = Mode.ssh, this.jump = '', this.tag = ''}) : local = false;

  /// The local shell (SPEC 13): a shell on this device, in a sandbox of
  /// its own, never a server. Not stored with the hosts.
  Host.local()
      : name = 'local',
        user = '',
        address = '',
        jump = '',
        tag = '',
        port = 0,
        mode = Mode.ssh,
        local = true;

  String name, user, address, jump, tag;
  int port;
  Mode mode;
  final bool local;

  String get target => '$user@$address';

  Map<String, Object> toJson() => {'name': name, 'user': user, 'address': address, 'port': port, 'mode': mode.name, 'jump': jump, 'tag': tag};

  static Host fromJson(Map<String, dynamic> j) => Host(
        name: j['name'] as String? ?? '',
        user: j['user'] as String? ?? '',
        address: j['address'] as String? ?? '',
        port: j['port'] as int? ?? 22,
        mode: (j['mode'] as String?) == 'pylon' ? Mode.pylon : Mode.ssh,
        jump: j['jump'] as String? ?? '',
        tag: j['tag'] as String? ?? '',
      );
}

/// A pinned key as `pylon pins` reports it.
class Pin {
  Pin(this.token, this.alg, this.fingerprint, this.when, this.by);
  final String token, alg, fingerprint, when, by;
}

/// The outcome of a command the core ran (pin, trust a CA, ...).
class Outcome {
  Outcome(this.ok, this.message);
  final bool ok;
  final String message;
}

/// What the app's agent said about its keys (see [Session.agentKeys]).
enum AgentKeys { unknown, some, none, unreachable }

/// A live terminal: the latest screen from the confined emulator, its
/// title, and how it ended. [changes] fires on every update.
abstract class Session {
  Session(this.host);
  final Host host;
  bool get local => host.local;
  Screen screen = Screen.blank(24, 80);

  /// The emulator's scrollback as far as fetched; its `request` is set by
  /// a session that has an emulator to ask.
  final Scrollback scrollback = Scrollback();
  String title = '';
  int? exitCode;
  String status = '';

  /// What the app's agent (Symbolon, on Android) answered when the core
  /// asked for its keys: [AgentKeys.none] for an empty list,
  /// [AgentKeys.unreachable] when Pylon could not reach it.
  AgentKeys agentKeys = AgentKeys.unknown;
  final List<Uint8List> clipboardRequests = [];
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void changed() => _changes.add(null);

  void input(List<int> bytes);
  void resize(int rows, int cols);
  void close();
}

abstract class Backend {
  Future<List<Host>> loadHosts();
  Future<void> saveHosts(List<Host> hosts);
  Future<List<Pin>> pins();
  Future<Outcome> pin(Host h, String fingerprint);
  Future<Outcome> trustCa(String pattern, String key);
  Session open(Host h, int rows, int cols);

  /// A file browser's connection to the host (SPEC 11), over SSH.
  FileSession openFiles(Host h);
  bool get demo;

  /// Whether this device can run the local shell (SPEC 13).
  bool get hasLocalShell;

  /// A new local shell. [shareNet] (Linux only) leaves it the device's
  /// network instead of none.
  Session openLocal(int rows, int cols, {bool shareNet = false});
}
