// `pylon authorize --app` against a stub core: its arguments, the agent
// request relayed and answered, the report read across frames, and a
// failure's messages.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/access.dart';
import 'package:pylon/backend/frames.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/backend/process_backend.dart';

Future<Directory> stub({required int exit, String err = '', int reply = 14}) async {
  final dir = await Directory.systemTemp.createTemp('pylon-authorize');
  // One agent request (a key list), its answer read back, then the report
  // in two frames that split a line.
  await File('${dir.path}/req.bin').writeAsBytes(frame(3, [0, 0, 0, 1, 11]));
  await File('${dir.path}/out.bin').writeAsBytes([
    ...frame(1, utf8.encode('added ssh-ed25519 SHA256:abc alice@laptop\npres')),
    ...frame(1, utf8.encode('ent ecdsa-sha2-nistp256 SHA256:def\ndone\n')),
  ]);
  await File('${dir.path}/pylon').writeAsString('#!/bin/sh\n'
      'd=\$(dirname "\$0")\n'
      'printf "%s\\n" "\$@" > "\$d/args"\n'
      'cat "\$d/req.bin"\n'
      'head -c $reply > "\$d/reply"\n'
      'cat "\$d/out.bin"\n'
      '${err.isEmpty ? '' : 'printf "%s" "$err" >&2\n'}'
      'exit $exit\n');
  await Process.run('chmod', ['+x', '${dir.path}/pylon']);
  return dir;
}

Future<void> ended(Authorize a) async {
  final done = Completer<void>();
  a.changes.listen((_) {
    if (a.ok != null && !done.isCompleted) done.complete();
  });
  if (a.ok == null) await done.future.timeout(const Duration(seconds: 10));
}

void main() {
  test('a run: arguments, the agent relayed, the report', () async {
    final dir = await stub(exit: 0);
    final b = ProcessBackend(dir.path, dir.path)..agent = (conn, req) async => Uint8List.fromList([0, 0, 0, 5, 12, 0, 0, 0, 0]);
    final h = Host(name: 'nas', user: 'larry', address: 'nas.lan', port: 2222, jump: 'j@jump');
    final a = b.authorize(h, ['ssh-ed25519 AAAA x'], ca: true);
    await ended(a);
    expect(a.ok, true);
    expect((await File('${dir.path}/args').readAsString()).trim().split('\n'), ['authorize', '--app', '-p', '2222', '-J', 'j@jump', '--ca', 'larry@nas.lan', 'ssh-ed25519 AAAA x']);
    expect(await File('${dir.path}/reply').readAsBytes(), frame(3, [0, 0, 0, 5, 12, 0, 0, 0, 0]));
    expect(a.agentNote, 'Symbolon offered no keys.');
    expect([for (final l in a.lines) l.kind], [ReportKind.added, ReportKind.present, ReportKind.done]);
    expect(a.lines[1].text, 'ecdsa-sha2-nistp256 SHA256:def');
    await dir.delete(recursive: true);
  });

  test("a failure keeps the core's words", () async {
    // No agent: the failure message (SSH_AGENT_FAILURE) goes back.
    final dir = await stub(exit: 1, err: "pylon: larry@nas.lan accepted none of the agent's keys.", reply: 10);
    final b = ProcessBackend(dir.path, dir.path);
    final a = b.authorize(Host(name: 'nas', user: 'larry', address: 'nas.lan'), const []);
    await ended(a);
    expect(a.ok, false);
    expect(parseKeyRefusal(a.messages)?.target, 'larry@nas.lan');
    expect(await File('${dir.path}/reply').readAsBytes(), frame(3, [0, 0, 0, 1, 5]));
    expect((await File('${dir.path}/args').readAsString()).trim().split('\n'), ['authorize', '--app', '-p', '22', 'larry@nas.lan']);
    await dir.delete(recursive: true);
  });
}
