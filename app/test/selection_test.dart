// Pylon's own selection: a long press selects the word under the finger
// and a drag before letting go extends it; handles move either end; Copy
// puts it on the clipboard without a prompt; a tap clears it. Kept to the
// tmux pane it began in when "Pane only" is on. And the clipboard prompt
// for a program's OSC 52 writes: one sheet, offering the latest.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/clip.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/term/screen.dart';
import 'package:pylon/term/term_view.dart';
import 'package:pylon/theme.dart';
import 'package:pylon/ui/prompts.dart';

import 'fakes.dart';

Screen text(int rows, int cols, List<String> lines, {int modes = 3}) {
  final s = Screen.blank(rows, cols);
  for (var y = 0; y < lines.length; y++) {
    final r = lines[y].runes.toList();
    for (var x = 0; x < r.length && x < cols; x++) {
      s.cp[y * cols + x] = r[x];
    }
  }
  return Screen(rows, cols, 0, rows - 1, modes, s.cp, s.attr);
}

// Two tmux panes side by side, split by a line, a status line on top.
final split = text(6, 30, [
  ' main  1:zsh                  ',
  'left one     │right one       ',
  'left two     │right two       ',
  'left three   │right three     ',
  '─────────────┼────────────────',
  'bottom pane  │corner          ',
]);

Offset cellAt(WidgetTester tester, int x, int y) {
  final tp = TextPainter(text: const TextSpan(text: 'M', style: TextStyle(fontFamily: mono, fontSize: 13, height: 1.25)), textDirection: TextDirection.ltr)..layout();
  final box = tester.renderObject<RenderBox>(find.byType(TermView));
  return box.localToGlobal(Offset(8 + (x + 0.5) * tp.width, 4 + (y + 0.5) * tp.height));
}

Future<(GlobalKey<TermViewState>, List<List<int>>)> pump(WidgetTester tester, Screen s) async {
  final view = GlobalKey<TermViewState>();
  final sent = <List<int>>[];
  await tester.pumpWidget(MaterialApp(
    theme: pylonTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 800, height: 500, child: TermView(key: view, screen: s, onInput: sent.add, onResize: (_, _) {})),
      ),
    ),
  ));
  return (view, sent);
}

Future<TestGesture> longPress(WidgetTester tester, int x, int y) async {
  final g = await tester.startGesture(cellAt(tester, x, y));
  await tester.pump(TermViewState.longHold + const Duration(milliseconds: 50));
  return g;
}

void main() {
  setUp(() => TermViewState.paneOnly = true);

  test('the pane around a cell, words, and the text between two cells', () {
    expect(split.paneAt(2, 2), (0, 0, 12, 3), reason: 'bounded by the split lines, not the status line');
    expect(split.paneAt(16, 1), (14, 0, 29, 3));
    expect(split.paneAt(1, 5), (0, 5, 12, 5));
    expect(split.paneAt(13, 2), (13, 2, 13, 2), reason: 'a border is its own pane');
    expect(split.wordAt(7, 3), (5, 9));
    expect(split.wordAt(4, 3), (4, 4), reason: 'a blank is a word of its own');
    expect(split.textBetween((5, 1), (3, 3)), 'one     │right one\nleft two     │right two\nleft');
    expect(split.textBetween((3, 3), (5, 1), pane: split.paneAt(5, 1)), 'one\nleft two\nleft', reason: 'either order; the pane only');
  });

  testWidgets('a long press selects the word; a drag extends it; Copy copies without a prompt', (tester) async {
    final (view, sent) = await pump(tester, text(24, 80, ['echo hello world', 'second line here']));
    final g = await longPress(tester, 6, 0);
    expect(view.currentState!.selection, 'hello');
    await g.moveTo(cellAt(tester, 5, 1));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(view.currentState!.selection, 'hello world\nsecond');

    final clip = fakeClipboard(tester);
    await tester.tap(find.byKey(const Key('sel-copy')));
    await tester.pump();
    expect(clip.text, 'hello world\nsecond');
    expect(view.currentState!.selecting, false);
    expect(sent, isEmpty);
    expect(find.byType(BottomSheet), findsNothing);
    // Cleared after 60 seconds, still being ours (SPEC 15).
    await tester.pump(const Duration(seconds: 59));
    expect(clip.text, 'hello world\nsecond');
    await tester.pump(const Duration(seconds: 2));
    expect(clip.text, '');
  });

  testWidgets('a drag before the long press scrolls instead; a tap clears a selection', (tester) async {
    final (view, _) = await pump(tester, text(24, 80, ['echo hello']));
    final g = await tester.startGesture(cellAt(tester, 6, 0));
    await g.moveBy(const Offset(0, 40));
    await tester.pump(TermViewState.longHold);
    await g.up();
    expect(view.currentState!.selecting, false);

    await (await longPress(tester, 6, 0)).up();
    await tester.pump();
    expect(view.currentState!.selecting, true, reason: 'the long press\'s own lift keeps it');
    await tester.tapAt(cellAt(tester, 20, 10));
    await tester.pump();
    expect(view.currentState!.selecting, false);
  });

  testWidgets('a handle moves its end', (tester) async {
    final (view, _) = await pump(tester, text(24, 80, ['one two three four']));
    await (await longPress(tester, 5, 0)).up();
    await tester.pump();
    expect(view.currentState!.selection, 'two');
    final w = cellAt(tester, 1, 0).dx - cellAt(tester, 0, 0).dx;
    await tester.drag(find.byKey(const Key('sel-end')), Offset(w * 6, 0));
    await tester.pump();
    expect(view.currentState!.selection, 'two three');
    await tester.drag(find.byKey(const Key('sel-start')), Offset(-w * 4, 0));
    await tester.pump();
    expect(view.currentState!.selection, 'one two three');
  });

  testWidgets('in tmux, a selection keeps to its pane unless Pane only is off', (tester) async {
    final (view, _) = await pump(tester, split);
    final g = await longPress(tester, 6, 1);
    await g.moveTo(cellAt(tester, 20, 3));
    await g.up();
    await tester.pump();
    expect(view.currentState!.selection, 'one\nleft two\nleft three', reason: 'no split line, nothing of the pane beside it');
    await tester.tap(find.byKey(const Key('sel-pane')));
    await tester.pump();
    expect(TermViewState.paneOnly, false);
    expect(view.currentState!.selection, 'one     │right one\nleft two     │right two\nleft three   │right t');
    await tester.tap(find.byKey(const Key('sel-pane')));
    await tester.tap(find.byKey(const Key('sel-all')));
    await tester.pump();
    expect(view.currentState!.selection, ' main  1:zsh\nleft one\nleft two\nleft three');
  });

  Uint8List req(String t) => Uint8List.fromList(base64.encode(utf8.encode(t)).codeUnits);

  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }))));
    return ctx;
  }

  testWidgets('a program copying again and again gets one sheet; what it shows is what Allow copies', (tester) async {
    final s = FakeSession(Host.local());
    final ctx = await host(tester);
    final clip = fakeClipboard(tester);
    s.clipboardRequests.add(req('first'));
    askClipboard(ctx, s);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('clip-waiting')), findsNothing);
    for (final t in ['second', 'third']) {
      s.clipboardRequests.add(req(t));
      askClipboard(ctx, s);
      await tester.pumpAndSettle();
    }
    expect(find.byType(BottomSheet), findsOneWidget, reason: "writes don't stack sheets");
    expect(find.text('first'), findsOneWidget, reason: 'the open sheet never changes what it offers');
    expect(find.text('third'), findsNothing);
    expect(find.byKey(const Key('clip-waiting')), findsOneWidget);
    expect(s.clipboardRequests, isEmpty);

    await tester.tap(find.byKey(const Key('clip-allow')));
    await tester.pumpAndSettle();
    expect(clip.text, 'first', reason: 'Allow copies what the principal read');
    expect(clip.writes, 1);

    // The latest of the writes that came meanwhile, in a sheet of its own.
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('third'), findsOneWidget);
    expect(find.text('second'), findsNothing, reason: 'only the latest waits');
    expect(find.byKey(const Key('clip-waiting')), findsNothing);
    await tester.tap(find.byKey(const Key('clip-deny')));
    await tester.pumpAndSettle();
    expect(clip.text, 'first', reason: "don't allow copies nothing");
    expect(clip.writes, 1);
    expect(find.byType(BottomSheet), findsNothing);

    // The copy expires after 60 seconds.
    await tester.pump(const Duration(seconds: 61));
    expect(clip.text, '');
  });

  testWidgets('the sheet shows all of the text, escaped, with its length and lines', (tester) async {
    final s = FakeSession(Host(name: 'build-01', user: 'u', address: '10.0.0.1'));
    final ctx = await host(tester);
    fakeClipboard(tester);
    final long = '${List.generate(80, (i) => 'line $i ${'x' * 30}').join('\n')}\nrm -rf ~ \u202Egnp.exe\u001b[2J END';
    s.clipboardRequests.add(req(long));
    askClipboard(ctx, s);
    await tester.pumpAndSettle();
    expect(find.text('Let build-01 copy to your clipboard?'), findsOneWidget);
    final offer = tester.widget<Text>(find.byKey(const Key('clip-offer')));
    final shown = offer.data!;
    expect(shown, contains('line 0 '));
    expect(shown, contains('line 79 '));
    expect(shown, endsWith('rm -rf ~ <U+202E>gnp.exe<U+001B>[2J END'), reason: 'all of it, its controls shown as codes');
    expect(shown, isNot(contains('\u202E')));
    expect(offer.style!.fontFamily, mono);
    final (chars, lines) = clipStats(long);
    expect(lines, 81);
    expect(find.text('$chars characters · 81 lines'), findsOneWidget);
    // Too long for the sheet: it scrolls, and the buttons stay in reach.
    expect(find.byKey(const Key('clip-allow')).hitTestable(), findsOneWidget);
    await tester.drag(find.byKey(const Key('clip-scroll')), const Offset(0, -5000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clip-deny')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  test('clipStats counts characters and lines', () {
    expect(clipStats(''), (0, 0));
    expect(clipStats('a'), (1, 1));
    expect(clipStats('a\n'), (2, 1));
    expect(clipStats('a\nb'), (3, 2));
    expect(clipStats('\u{1F600}'), (1, 1), reason: 'characters, not UTF-16 units');
  });

  testWidgets('an expiring copy leaves alone what was copied since', (tester) async {
    final clip = fakeClipboard(tester);
    final e = ExpiringClipboard();
    await e.copy('secret');
    clip.text = 'something else';
    await tester.pump(const Duration(seconds: 61));
    expect(clip.text, 'something else');
    await e.copy('one');
    await tester.pump(const Duration(seconds: 30));
    await e.copy('two');
    await tester.pump(const Duration(seconds: 31));
    expect(clip.text, 'two', reason: 'a newer copy restarts the clock');
    await tester.pump(const Duration(seconds: 30));
    expect(clip.text, '');
  });
}

/// The platform clipboard, in memory.
class FakeClip {
  String? text;
  int writes = 0;
}

FakeClip fakeClipboard(WidgetTester tester) {
  final clip = FakeClip();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
    if (c.method == 'Clipboard.setData') {
      clip.text = (c.arguments as Map)['text'] as String;
      clip.writes++;
    }
    if (c.method == 'Clipboard.getData') return clip.text == null ? null : {'text': clip.text};
    return null;
  });
  return clip;
}
