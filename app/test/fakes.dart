import 'dart:typed_data';

import 'package:pylon/backend/access.dart';
import 'package:pylon/backend/files.dart';
import 'package:pylon/backend/mem_files.dart';
import 'package:pylon/backend/model.dart';

/// A session that records what the interface did to it.
class FakeSession extends Session {
  FakeSession(super.host);
  final List<List<int>> inputs = [];
  final List<(int, int)> sizes = [];
  bool closed = false;

  @override
  void input(List<int> bytes) => inputs.add(bytes);
  @override
  void resize(int rows, int cols) => sizes.add((rows, cols));
  @override
  void close() {
    closed = true;
    exitCode ??= 0;
    changed();
  }
}

class FakeBackend implements Backend {
  final List<FakeSession> opened = [];
  final hosts = [Host(name: 'build-01', user: 'alice', address: '10.0.8.21'), Host(name: 'prod-db', user: 'ops', address: '10.0.4.12', tag: 'production')];

  @override
  bool get demo => false;
  @override
  bool get hasLocalShell => true;
  @override
  Future<List<Host>> loadHosts() async => hosts;
  @override
  Future<void> saveHosts(List<Host> hosts) async {}
  @override
  Future<List<Pin>> pins() async => [Pin('10.0.8.21:22', 'ssh-ed25519', 'SHA256:x', '', ''), Pin('10.0.4.12:22', 'ssh-ed25519', 'SHA256:y', '', '')];
  @override
  Future<Outcome> pin(Host h, String fingerprint) async => Outcome(false, '');
  @override
  Future<Outcome> trustCa(String pattern, String key) async => Outcome(false, '');
  @override
  Session open(Host h, int rows, int cols, {int? attach}) {
    attached.add(attach);
    return _add(FakeSession(h));
  }

  /// The `attach` each [open] was given, in order.
  final List<int?> attached = [];

  /// The file sessions opened, newest last.
  final List<MemFiles> files = [];
  Map<String, Uint8List?>? tree;
  @override
  FileSession openFiles(Host h) {
    final f = MemFiles(h, tree: tree);
    files.add(f);
    return f;
  }
  /// The authorize runs started, newest last.
  final List<FakeAuthorize> authorized = [];
  @override
  Authorize authorize(Host h, List<String> keys, {bool ca = false}) {
    final a = FakeAuthorize(h, keys, ca: ca);
    authorized.add(a);
    return a;
  }

  @override
  Session openLocal(int rows, int cols, {bool shareNet = false}) => _add(FakeSession(Host.local()));

  FakeSession _add(FakeSession s) {
    opened.add(s);
    return s;
  }
}

/// An authorize run the test finishes by hand.
class FakeAuthorize extends Authorize {
  FakeAuthorize(super.host, super.keys, {super.ca});
  bool closed = false;

  void finish(bool ok, {List<ReportLine> report = const [], String messages = ''}) {
    lines.addAll(report);
    this.messages = messages;
    this.ok = ok;
    changed();
  }

  @override
  void close() => closed = true;
}
