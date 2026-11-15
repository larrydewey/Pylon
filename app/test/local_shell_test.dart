// The local shell's backend (SPEC 13): pylon-local as a stub process on
// Linux, and a stub conduit standing in for Android's isolated service.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/frames.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/backend/process_backend.dart';
import 'package:pylon/theme.dart';
import 'package:pylon/ui/app_state.dart';
import 'package:pylon/ui/sessions_page.dart';
import 'package:pylon/ui/terminal_page.dart';

import 'fakes.dart';

Future<void> ended(Session s) async {
  final done = Completer<void>();
  final sub = s.changes.listen((_) {
    if (s.exitCode != null && !done.isCompleted) done.complete();
  });
  if (s.exitCode != null) done.complete();
  await done.future.timeout(const Duration(seconds: 10));
  await sub.cancel();
}

/// A conduit fed by the test (Android's service, in effect).
class StubConduit implements Conduit {
  final out = StreamController<List<int>>();
  final msgs = StreamController<String>();
  final exit = Completer<int>();
  final sent = <int>[];
  bool closed = false;

  @override
  Stream<List<int>> get output => out.stream;
  @override
  Stream<String> get messages => msgs.stream;
  @override
  void add(List<int> f) => sent.addAll(f);
  @override
  Future<int> get exitCode => exit.future;
  @override
  void close() => closed = true;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pylon-local-stub');
    // pylon-term: reads frames and draws nothing.
    await File('${dir.path}/pylon-term').writeAsString('#!/bin/sh\ncat > /dev/null\n');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> stub(String body) async {
    await File('${dir.path}/pylon-local').writeAsString('#!/bin/sh\nD=${dir.path}\n$body\n');
    await Process.run('chmod', ['+x', '${dir.path}/pylon-local', '${dir.path}/pylon-term']);
  }

  test('pylon-local: held keys after ready, the reported exit status, a confined environment', () async {
    // Ready, then the 17 bytes the app sends (a size frame, then "ls\r"),
    // then status 3 as frame 5 and a process exit of 0 (as a launcher that
    // confined itself leaves it).
    await stub(r'''
env > "$D/env"
echo "$@" > "$D/args"
printf '\004\000\000\000\000'
head -c 17 > "$D/in"
printf '\005\000\000\000\001\003'
exit 0''');
    final b = ProcessBackend(dir.path, '${dir.path}/pylon-home');
    expect(b.hasLocalShell, true);
    final s = b.openLocal(10, 40);
    expect(s.local, true);
    s.input([108, 115, 13]);
    await ended(s);
    expect(s.exitCode, 3, reason: 'frame 5 wins over the process status');
    expect(File('${dir.path}/args').readAsStringSync().trim(), '10 40');
    final got = File('${dir.path}/in').readAsBytesSync();
    // Typed before the launcher even started: held until ready, then sent.
    expect(got, [...frame(1, [108, 115, 13]), ...frame(2, [0, 10, 0, 40])], reason: 'keys wait for ready');
    final env = {
      for (final l in File('${dir.path}/env').readAsLinesSync())
        if (l.contains('=')) l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
    };
    env.remove('PWD');
    env.remove('SHLVL');
    env.remove('_');
    expect(env.keys.toSet().difference({'HOME', 'SHELL', 'LANG', 'USER', 'SSH_AUTH_SOCK', 'PYLON_HOME', 'PATH'}), isEmpty,
        reason: 'pylon-local gets only what it needs to place and check the local home');
    expect(env['PYLON_HOME'], '${dir.path}/pylon-home');
    expect(env.containsKey('PYLON_AGENT'), false);
  });

  test('pylon-local: --share-net when asked; closing ends it', () async {
    await stub(r'''
echo "$@" > "$D/args"
printf '\004\000\000\000\000'
cat > /dev/null''');
    final b = ProcessBackend(dir.path, dir.path);
    final s = b.openLocal(24, 80, shareNet: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(File('${dir.path}/args').readAsStringSync().trim(), '--share-net 24 80');
    s.close();
    await ended(s);
    expect(s.exitCode, isNot(0));
  });

  test('a launcher that refuses: its message is the session status', () async {
    await stub(r'''
echo "pylon-local: HOME must be an absolute path without spaces or quotes; the local shell does not start" >&2
exit 1''');
    final s = ProcessBackend(dir.path, dir.path).openLocal(24, 80);
    await ended(s);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(s.exitCode, 1);
    expect(s.status, contains('does not start'));
  });

  test('no pylon-local beside the core: no local shell offered', () {
    expect(ProcessBackend('${dir.path}/nowhere', dir.path).hasLocalShell, false);
  });

  test('Android: the service conduit: frames both ways, status from frame 5, no agent', () async {
    await Process.run('chmod', ['+x', '${dir.path}/pylon-term']);
    final c = StubConduit();
    var asked = 0;
    final b = ProcessBackend.at('${dir.path}/pylon', '${dir.path}/pylon-term', dir.path, dir.path,
        localConduit: (r, k) async => c, agent: (conn, req) async {
      asked++;
      return null;
    });
    expect(b.hasLocalShell, true);
    final s = b.openLocal(24, 80);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    s.input([97]);
    expect(c.sent, isEmpty, reason: 'nothing before ready');
    c.out.add(frame(3, [0, 0, 0, 1, 11])); // an agent request: the local shell gets none
    c.out.add(frame(4, []));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.sent, [...frame(2, [0, 24, 0, 80]), ...frame(1, [97])]);
    expect(asked, 0);
    c.out.add(frame(5, [9]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    c.exit.complete(255);
    await ended(s);
    expect(s.exitCode, 9);
    s.close();
    expect(c.closed, true);
  });

  testWidgets('the local shell page is purple and says what it cannot reach', (tester) async {
    final be = FakeBackend();
    final st = AppState(be);
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: TerminalPage(st: st, host: Host.local())));
    await tester.pump();
    expect(be.opened.single.local, true);
    expect(find.textContaining('Local shell · '), findsOneWidget);
    expect(find.text('Sandboxed · no network to your hosts · no keys'), findsOneWidget);
    expect(find.textContaining("Pylon's files, agent or sessions"), findsOneWidget);
    // One local shell at a time on a phone: opening it again finds it.
    expect(st.open(Host.local(), 24, 80), same(be.opened.single));
  });

  testWidgets('the sessions page offers the local shell, on this device only', (tester) async {
    final st = AppState(FakeBackend());
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: Scaffold(body: SessionsPage(st: st))));
    expect(find.text('Local shell'), findsOneWidget);
    expect(find.text('Separate sandbox, no access to your keys'), findsOneWidget);
    await tester.tap(find.text('Local shell'));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalPage), findsOneWidget);
  });

  // The real thing, when the core is built: PYLON_LOCAL_TEST_BIN=build
  // (pylon-local and pylon-term there), as tests/local_shell.sh runs it.
  final realBin = Platform.environment['PYLON_LOCAL_TEST_BIN'];
  test('the real pylon-local through the real pylon-term: screens, size, exit status', () async {
    final home = await Directory.systemTemp.createTemp('pylon-local-home');
    final b = ProcessBackend(realBin!, '${home.path}/.config/pylon');
    final s = b.openLocal(20, 70);
    String text() => [for (var y = 0; y < s.screen.rows; y++) s.screen.rowText(y)].join('\n');
    Future<void> until(String needle) async {
      final done = Completer<void>();
      final sub = s.changes.listen((_) {
        if (text().contains(needle) && !done.isCompleted) done.complete();
      });
      if (text().contains(needle)) done.complete();
      await done.future.timeout(const Duration(seconds: 20), onTimeout: () => throw TimeoutException('no "$needle"; status ${s.status}; screen:\n${text()}'));
      await sub.cancel();
    }

    s.input('echo hi-\$((6*7)); stty size\r'.codeUnits);
    await until('hi-42');
    await until('20 70');
    s.resize(25, 90);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    s.input('stty size; exit 5\r'.codeUnits);
    await ended(s);
    expect(text(), contains('25 90'));
    expect(s.exitCode, 5);
    await home.delete(recursive: true);
  }, skip: realBin == null ? 'set PYLON_LOCAL_TEST_BIN to a directory with pylon-local and pylon-term' : null, timeout: const Timeout(Duration(seconds: 60)));

  test('frames survive the trip through the conduit unchanged', () {
    final r = FrameReader();
    expect(r.add(Uint8List.fromList(frame(5, [7]))).single.$2, [7]);
  });
}
