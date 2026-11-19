import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/frames.dart';
import 'package:pylon/term/keys.dart';
import 'package:pylon/term/screen.dart';

void main() {
  test('keys: arrows follow application cursor mode; ctrl letters', () {
    expect(KeyEncoder.encode(LogicalKeyboardKey.arrowUp, ctrl: false, alt: false, shift: false, appCursor: false), utf8.encode('\x1b[A'));
    expect(KeyEncoder.encode(LogicalKeyboardKey.arrowUp, ctrl: false, alt: false, shift: false, appCursor: true), utf8.encode('\x1bOA'));
    expect(KeyEncoder.text('c', ctrl: true, alt: false), [3]);
    expect(KeyEncoder.text('x', ctrl: false, alt: true), [27, 120]);
  });

  test('paste: markers inside the text are removed; confirmation rules', () {
    final p = KeyEncoder.paste('a\x1b[201~rm -rf ~\nb', bracketed: true);
    expect(utf8.decode(p), '\x1b[200~arm -rf ~\rb\x1b[201~');
    expect(KeyEncoder.pasteNeedsConfirm('ls\n', bracketed: false), true);
    expect(KeyEncoder.pasteNeedsConfirm('ls', bracketed: false), false);
    expect(KeyEncoder.pasteNeedsConfirm('x\x1b[201~y', bracketed: true), true);
  });

  test('paste: nested markers cannot leave a marker behind', () {
    // Removing the inner marker of each joins its neighbours into another.
    const hostile = 'ls\x1b[20\x1b[2\x1b[200~01~1~\nid>/tmp/pwned\n';
    final body = utf8.decode(KeyEncoder.paste(hostile, bracketed: true));
    final inner = body.substring(6, body.length - 6);
    expect(body.startsWith('\x1b[200~') && body.endsWith('\x1b[201~'), true);
    expect(inner.contains('\x1b[201~'), false);
    expect(inner.contains('\x1b[200~'), false);
    expect(KeyEncoder.pasteNeedsConfirm(hostile, bracketed: true), true);
    expect(KeyEncoder.stripPasteMarkers('\x1b[20\x1b[201~1~'), '');
    expect(KeyEncoder.pasteNeedsConfirm('plain\ntext', bracketed: true), false);
  });

  test('frames: split and joined reads', () {
    final r = FrameReader();
    final f = frame(1, [1, 2, 3]) + frame(2, [9]);
    expect(r.add(f.sublist(0, 4)), isEmpty);
    final got = r.add(f.sublist(4));
    expect(got.length, 2);
    expect(got[0].$1, 1);
    expect(got[0].$2, [1, 2, 3]);
    expect(got[1].$2, [9]);
  });

  test('screen: decodes a pylon-term frame', () {
    final b = BytesBuilder()..add([0, 1, 0, 2, 0, 1, 0, 0, 0, 0, 0, 3]);
    for (final c in [72, 105]) {
      b.add([0, 0, 0, c, 0, 2, 0, 0]);
    }
    final s = Screen.decode(b.toBytes())!;
    expect(s.rows, 1);
    expect(s.cols, 2);
    expect(s.rowText(0), 'Hi');
    expect(s.cursorVisible, true);
    expect(Screen.decode(Uint8List(5)), isNull);
  });
}
