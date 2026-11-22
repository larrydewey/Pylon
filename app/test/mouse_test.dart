// Touch as mouse: reports in the encoding the program asked for, and the
// gestures that make them (a tap clicks, a drag after a rest holds the
// button, a swipe or two fingers turn the wheel), only while it asks; a
// long press is Pylon's own selection (selection_test.dart).
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/term/keys.dart';
import 'package:pylon/term/screen.dart';
import 'package:pylon/term/term_view.dart';
import 'package:pylon/theme.dart';

const click = 256, drag = 512, sgr = 2048;

Screen screenWith(int modes) {
  final s = Screen.blank(24, 80);
  return Screen(24, 80, 0, 0, 3 | modes, s.cp, s.attr);
}

String str(List<int> b) => String.fromCharCodes(b);

Future<(List<String>, GlobalKey<TermViewState>, List<(int, int)>)> pump(WidgetTester tester, int modes, {bool mouse = true}) async {
  final sent = <String>[];
  final asked = <(int, int)>[];
  final sb = Scrollback()..take(_empty(300));
  sb.request = (f, c) => asked.add((f, c));
  final view = GlobalKey<TermViewState>();
  await tester.pumpWidget(MaterialApp(
    theme: pylonTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 800, height: 500, child: TermView(key: view, screen: screenWith(modes), scrollback: sb, mouse: mouse, onInput: (b) => sent.add(str(b)), onResize: (_, _) {})),
      ),
    ),
  ));
  return (sent, view, asked);
}

Uint8List _empty(int total) => Uint8List.fromList([0, 0, (total >> 8) & 255, total & 255, 0, 0, 0, 0, 0, 0]);

// The middle of the cell at column x, row y: cells are measured as the
// view measures them, from its padding's corner.
Offset cellAt(WidgetTester tester, int x, int y) {
  final tp = TextPainter(text: const TextSpan(text: 'M', style: TextStyle(fontFamily: mono, fontSize: 13, height: 1.25)), textDirection: TextDirection.ltr)..layout();
  final box = tester.renderObject<RenderBox>(find.byType(TermView));
  return box.localToGlobal(Offset(8 + (x + 0.5) * tp.width, 4 + (y + 0.5) * tp.height));
}

void main() {
  test('reports: SGR and X10, presses, releases, motion and the wheel', () {
    expect(str(MouseEncoder.report(MouseEncoder.left, 0, 0, sgr: true)!), '\x1b[<0;1;1M');
    expect(str(MouseEncoder.report(MouseEncoder.left, 4, 2, sgr: true, release: true)!), '\x1b[<0;5;3m');
    expect(str(MouseEncoder.report(MouseEncoder.left + MouseEncoder.motion, 9, 0, sgr: true)!), '\x1b[<32;10;1M');
    expect(str(MouseEncoder.report(MouseEncoder.wheelUp, 300, 0, sgr: true)!), '\x1b[<64;301;1M');
    expect(MouseEncoder.report(MouseEncoder.right, 0, 0, sgr: false), [27, 91, 77, 32 + 2, 33, 33]);
    expect(MouseEncoder.report(MouseEncoder.right | MouseEncoder.ctrl, 1, 1, sgr: false, release: true), [27, 91, 77, 32 + 3 + 16, 34, 34]);
    expect(MouseEncoder.report(MouseEncoder.left, 223, 0, sgr: false), isNull, reason: 'beyond what X10 bytes hold');
  });

  test('the screen says which reports the program asked for', () {
    expect(screenWith(0).mouseTrack, 0);
    expect(screenWith(click).mouseTrack, 1000);
    expect(screenWith(click | drag).mouseTrack, 1002, reason: 'never both from the emulator, the larger wins');
    expect(screenWith(1024).mouseTrack, 1003);
    expect(screenWith(sgr).mouseSgr, true);
    expect(screenWith(sgr).mouseTrack, 0);
  });

  testWidgets('a tap is a click on the cell under the finger', (tester) async {
    final (sent, _, _) = await pump(tester, click | sgr);
    await tester.tapAt(cellAt(tester, 0, 0));
    await tester.pump();
    expect(sent, ['\x1b[<0;1;1M', '\x1b[<0;1;1m']);
    sent.clear();
    await tester.tapAt(cellAt(tester, 5, 3));
    await tester.pump();
    expect(sent, ['\x1b[<0;6;4M', '\x1b[<0;6;4m']);
  });

  testWidgets('a drag after a rest holds the button: press, motion over the cells, release', (tester) async {
    final (sent, view, asked) = await pump(tester, drag | sgr);
    final g = await tester.startGesture(cellAt(tester, 0, 0));
    await tester.pump(TermViewState.armHold + const Duration(milliseconds: 50));
    await g.moveBy(const Offset(0, 40));
    await g.moveBy(const Offset(0, 40));
    await g.up();
    await tester.pump();
    expect(sent.first, '\x1b[<0;1;1M');
    expect(sent.last, startsWith('\x1b[<0;1;'));
    expect(sent.last, endsWith('m'));
    final motion = sent.where((s) => s.startsWith('\x1b[<32;')).toList();
    expect(motion, isNotEmpty);
    expect(view.currentState!.offset, 0, reason: 'not the scrollback');
    expect(asked, isEmpty);
  });

  testWidgets('clicks only (1000): a drag is a press and a release, no motion', (tester) async {
    final (sent, _, _) = await pump(tester, click);
    final g = await tester.startGesture(cellAt(tester, 0, 0));
    await tester.pump(TermViewState.armHold + const Duration(milliseconds: 50));
    await g.moveBy(const Offset(0, 60));
    await g.up();
    await tester.pump();
    expect(sent.length, 2);
    expect(sent.first.codeUnits, [27, 91, 77, 32, 33, 33], reason: 'X10: no SGR asked');
    expect(sent.last.codeUnitAt(3), 32 + 3);
  });

  testWidgets('a long press selects, sending nothing: no right click', (tester) async {
    final (sent, view, _) = await pump(tester, click | sgr);
    final g = await tester.startGesture(cellAt(tester, 0, 0));
    await tester.pump(TermViewState.armHold);
    expect(sent, isEmpty, reason: 'armed for a drag');
    await tester.pump(TermViewState.longHold - TermViewState.armHold + const Duration(milliseconds: 50));
    await g.up();
    await tester.pump();
    expect(sent, isEmpty);
    expect(view.currentState!.selecting, true);
  });

  testWidgets('a swipe before the rest turns the wheel: no press, nothing selected', (tester) async {
    final (sent, view, _) = await pump(tester, drag | sgr);
    final g = await tester.startGesture(cellAt(tester, 2, 2));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, 20));
    }
    await tester.pump(TermViewState.longHold);
    await g.up();
    await tester.pump();
    expect(sent, isNotEmpty);
    expect(sent.every((s) => s.startsWith('\x1b[<64;')), true, reason: 'fingers down: wheel up, never a button');
    expect(view.currentState!.offset, 0);
  });

  testWidgets('two fingers turn the wheel', (tester) async {
    final (sent, _, _) = await pump(tester, drag | sgr);
    final a = await tester.startGesture(cellAt(tester, 2, 2), pointer: 1);
    final b = await tester.startGesture(cellAt(tester, 10, 2), pointer: 2);
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(0, 20));
      await b.moveBy(const Offset(0, 20));
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(sent, isNotEmpty);
    expect(sent.every((s) => s.startsWith('\x1b[<64;')), true, reason: 'fingers down: older lines, wheel up; no click or press');
  });

  testWidgets('with the mouse turned off, or not asked for, a drag scrolls back', (tester) async {
    for (final (modes, mouse) in [(drag | sgr, false), (0, true)]) {
      final (sent, view, _) = await pump(tester, modes, mouse: mouse);
      await tester.drag(find.byType(TermView), const Offset(0, 200));
      await tester.pump();
      expect(sent, isEmpty);
      expect(view.currentState!.offset, greaterThan(0));
    }
  });
}
