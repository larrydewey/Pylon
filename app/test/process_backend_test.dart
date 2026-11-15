// The real backend against a real server. Run by tests/interop.sh, which
// provides an sshd, an agent and a pinned host:
//   PYLON_BIN_DIR, PYLON_HOME, SSH_AUTH_SOCK, PYLON_TEST_TARGET (user@host),
//   PYLON_TEST_PORT
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/backend/process_backend.dart';

void main() {
  final env = Platform.environment;
  final target = env['PYLON_TEST_TARGET'];
  final skip = target == null ? 'set by tests/interop.sh' : null;

  Future<String> screenUntil(Session s, String needle) async {
    final done = Completer<String>();
    String text() => [for (var y = 0; y < s.screen.rows; y++) s.screen.rowText(y)].join('\n');
    final sub = s.changes.listen((_) {
      if (!done.isCompleted && text().contains(needle)) done.complete(text());
    });
    if (text().contains(needle)) done.complete(text());
    try {
      return await done.future.timeout(const Duration(seconds: 25), onTimeout: () => throw TimeoutException('no "$needle" on screen; status ${s.status}; screen:\n${text()}'));
    } finally {
      await sub.cancel();
    }
  }

  test('pins are listed with their fingerprints', () async {
    final b = ProcessBackend(env['PYLON_BIN_DIR']!, env['PYLON_HOME']!);
    final pins = await b.pins();
    expect(pins.any((p) => p.fingerprint.startsWith('SHA256:')), true);
  }, skip: skip);

  test('a terminal over SSH: screens from the confined emulator, size, exit status', () async {
    final b = ProcessBackend(env['PYLON_BIN_DIR']!, env['PYLON_HOME']!);
    final at = target!.split('@');
    final h = Host(name: 'test', user: at[0], address: at[1], port: int.parse(env['PYLON_TEST_PORT']!));
    final s = b.open(h, 20, 70);
    await Future<void>.delayed(const Duration(seconds: 2));
    s.input(utf8.encode("PS1='> '; stty size; echo from-app-\$((6*7))\r"));
    final t = await screenUntil(s, 'from-app-42');
    expect(t, contains('20 70'));
    s.resize(25, 90);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    s.input(utf8.encode('clear; stty size\r'));
    await screenUntil(s, '25 90');
    final ended = Completer<void>();
    s.changes.listen((_) {
      if (s.exitCode != null && !ended.isCompleted) ended.complete();
    });
    s.input(utf8.encode('exit 6\r'));
    await ended.future.timeout(const Duration(seconds: 20), onTimeout: () => throw TimeoutException('no exit; ps: ${Process.runSync('ps', ['-eo', 'pid,ppid,stat,wchan:20,args']).stdout.toString().split('\n').where((l) => l.contains('pylon')).join('\n')}; status ${s.status}; screen:\n${[for (var y = 0; y < s.screen.rows; y++) s.screen.rowText(y)].join('\n')}'));
    expect(s.exitCode, 6);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));
}
