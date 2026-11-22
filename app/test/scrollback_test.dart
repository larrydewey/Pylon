// Scrolling: the emulator's scrollback answers (frame 6), the view scrolled
// back over them, and the drag that scrolls, or sends arrow keys to a
// full-screen program.
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/term/screen.dart';
import 'package:pylon/term/term_view.dart';
import 'package:pylon/theme.dart';

// A type-6 payload: [total], [from], and one line per string.
Uint8List answer(int total, int from, List<String> lines) {
  final b = BytesBuilder();
  void u32(int v) => b.add([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]);
  u32(total);
  u32(from);
  b.add([(lines.length >> 8) & 255, lines.length & 255]);
  for (final l in lines) {
    b.add([(l.length >> 8) & 255, l.length & 255]);
    for (final c in l.codeUnits) {
      u32(c);
      u32(Screen.attrDefault);
    }
  }
  return b.toBytes();
}

Screen text(int rows, int cols, List<String> lines, {int modes = 3}) {
  final s = Screen.blank(rows, cols);
  for (var y = 0; y < lines.length; y++) {
    for (var x = 0; x < lines[y].length; x++) {
      s.cp[y * cols + x] = lines[y].codeUnitAt(x);
    }
  }
  return Screen(rows, cols, 0, rows - 1, modes, s.cp, s.attr);
}

void main() {
  test('an answer is taken: total, the run of lines, each its own width', () {
    final sb = Scrollback();
    expect(sb.take(answer(40, 0, [])), true);
    expect(sb.total, 40);
    expect(sb.rows, isEmpty);
    expect(sb.take(answer(40, 30, ['line 30', 'x'])), true);
    expect(sb.start, 30);
    expect(String.fromCharCodes(sb.at(30)!.cp), 'line 30');
    expect(sb.at(31)!.cp.length, 1);
    expect(sb.at(29), isNull);
    expect(sb.has(30, 2), true);
    expect(sb.has(30, 3), false);
    expect(sb.take(Uint8List.fromList([0, 0, 0, 1])), false, reason: 'short');
  });

  test('scrolled back: scrollback lines above the top of the screen, no cursor', () {
    final scr = text(3, 10, ['s0', 's1', 's2']);
    final sb = Scrollback()..take(answer(5, 0, ['h0', 'h1', 'h2', 'h3', 'h4']));
    final one = scr.scrolledBack(sb, 1);
    expect([for (var y = 0; y < 3; y++) one.rowText(y)], ['h4', 's0', 's1']);
    final four = scr.scrolledBack(sb, 4);
    expect([for (var y = 0; y < 3; y++) four.rowText(y)], ['h1', 'h2', 'h3']);
    expect(four.cursorVisible, false);
    expect(identical(scr.scrolledBack(sb, 0), scr), true);
    // Lines not fetched yet are blank, not someone else's.
    final partial = Scrollback()..take(answer(100, 98, ['h98', 'h99']));
    expect([for (var y = 0; y < 3; y++) scr.scrolledBack(partial, 4).rowText(y)], ['', '', 'h98']);
  });

  testWidgets('a drag asks for the scrollback, scrolls it, and typing returns to the live screen', (tester) async {
    final sb = Scrollback();
    final asked = <(int, int)>[];
    final sent = <List<int>>[];
    sb.request = (f, c) => asked.add((f, c));
    final scr = text(24, 80, ['live']);
    final view = GlobalKey<TermViewState>();
    await tester.pumpWidget(MaterialApp(
      theme: pylonTheme(),
      home: Scaffold(body: SizedBox(width: 400, height: 400, child: TermView(key: view, screen: scr, scrollback: sb, onInput: sent.add, onResize: (_, _) {}))),
    ));
    await tester.drag(find.byType(TermView), const Offset(0, 60));
    await tester.pump();
    expect(asked.first, (0, 0), reason: 'how much there is');

    sb.take(answer(300, 0, []));
    await tester.drag(find.byType(TermView), const Offset(0, 200));
    await tester.pump();
    expect(view.currentState!.offset, greaterThan(0));
    expect(asked.last.$2, 500, reason: 'the lines in view are fetched');
    expect(find.byKey(const Key('to-live')), findsOneWidget);

    view.currentState!.focus();
    await tester.enterText(find.byType(TextField), 'l');
    await tester.pump();
    expect(sent.last, 'l'.codeUnits);
    expect(view.currentState!.offset, 0);
    expect(find.byKey(const Key('to-live')), findsNothing);
  });

  testWidgets('a full-screen program gets arrow keys for a drag, not the scrollback', (tester) async {
    final sb = Scrollback()..take(answer(300, 0, []));
    final sent = <List<int>>[];
    final asked = <(int, int)>[];
    sb.request = (f, c) => asked.add((f, c));
    final alt = text(24, 80, ['less'], modes: 3 | 128);
    final view = GlobalKey<TermViewState>();
    await tester.pumpWidget(MaterialApp(
      theme: pylonTheme(),
      home: Scaffold(body: SizedBox(width: 400, height: 400, child: TermView(key: view, screen: alt, scrollback: sb, onInput: sent.add, onResize: (_, _) {}))),
    ));
    await tester.drag(find.byType(TermView), const Offset(0, 120));
    await tester.pump();
    expect(sent, isNotEmpty);
    expect(sent.every((b) => String.fromCharCodes(b) == '\x1b[A'), true, reason: 'up arrows: back toward older lines');
    expect(view.currentState!.offset, 0);
    expect(asked, isEmpty);
  });
}
