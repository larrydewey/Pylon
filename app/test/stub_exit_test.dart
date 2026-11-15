// The session reports the core's exit status. (A bare `exitCode` inside
// the session class once resolved to dart:io's top-level setter, the
// app's own exit status, so a session never ended.)
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/backend/process_backend.dart';

void main() {
  test('a session ends with the core\'s exit status', () async {
    final dir = await Directory.systemTemp.createTemp('pylon-stub');
    await File('${dir.path}/pylon').writeAsString('#!/bin/sh\nsleep 1\nexit 6\n');
    await File('${dir.path}/pylon-term').writeAsString('#!/bin/sh\ncat > /dev/null\n');
    await Process.run('chmod', ['+x', '${dir.path}/pylon', '${dir.path}/pylon-term']);
    final b = ProcessBackend(dir.path, dir.path);
    final s = b.open(Host(name: 'x', user: 'u', address: 'h'), 10, 10);
    final done = Completer<void>();
    s.changes.listen((_) {
      if (s.exitCode != null && !done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 10));
    expect(s.exitCode, 6);
    await dir.delete(recursive: true);
  });
}
