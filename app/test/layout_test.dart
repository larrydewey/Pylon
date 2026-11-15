// Tabs and splits (SPEC 15, Linux desktop): the pane tree on its own.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/desktop/layout.dart';

import 'fakes.dart';

void main() {
  final h = Host(name: 'h', user: 'u', address: 'a');
  late List<Session> ended;
  late Workspace ws;
  FakeSession s() => FakeSession(h);

  setUp(() {
    ended = [];
    ws = Workspace((x) {
      ended.add(x);
      x.close();
    });
  });

  test('a tab per session; the new one is active', () {
    final a = ws.openTab(s());
    final b = ws.openTab(s());
    expect(ws.tabs.length, 2);
    expect(ws.active, 1);
    expect(ws.focused, b);
    ws.select(0);
    expect(ws.focused, a);
    ws.cycle(1);
    expect(ws.active, 1);
    ws.cycle(1);
    expect(ws.active, 0, reason: 'cycling goes round');
    ws.cycle(-1);
    expect(ws.active, 1);
  });

  test('splits: right halves the width, down the height; the new pane has the focus', () {
    final a = ws.openTab(s());
    final b = ws.split(SplitDir.right, s());
    final c = ws.split(SplitDir.down, s());
    final t = ws.tab!;
    expect(t.panes, [a, b, c]);
    expect(ws.focused, c);
    final r = t.rects(const Rect.fromLTWH(0, 0, 1000, 800));
    expect(r[a], const Rect.fromLTWH(0, 0, 500, 800));
    expect(r[b], const Rect.fromLTWH(500, 0, 500, 400));
    expect(r[c], const Rect.fromLTWH(500, 400, 500, 400));
  });

  test('focus moves to the pane on that side, and nowhere past the edge', () {
    final a = ws.openTab(s());
    final b = ws.split(SplitDir.right, s());
    final c = ws.split(SplitDir.down, s());
    ws.move(Dir.left);
    expect(ws.focused, a);
    ws.move(Dir.left);
    expect(ws.focused, a, reason: 'nothing left of the leftmost pane');
    ws.move(Dir.right);
    expect(ws.focused, anyOf(b, c));
    ws.focus(b);
    ws.move(Dir.down);
    expect(ws.focused, c);
    ws.move(Dir.up);
    expect(ws.focused, b);
  });

  test('closing a pane ends its session; its sibling takes its place and the focus', () {
    final a = ws.openTab(s());
    final b = ws.split(SplitDir.right, s());
    final c = ws.split(SplitDir.down, s());
    ws.closePane(c);
    expect(ended, [c.session]);
    expect((c.session as FakeSession).closed, true);
    expect(ws.tab!.panes, [a, b]);
    expect(ws.focused, b);
    expect(ws.tab!.rects()[b], const Rect.fromLTWH(0.5, 0, 0.5, 1), reason: 'b has the whole right half again');
    ws.closePane(a);
    expect(ws.tab!.panes, [b]);
    expect(ws.tab!.rects()[b], const Rect.fromLTWH(0, 0, 1, 1));
  });

  test('closing an unfocused pane keeps the focus where it was', () {
    final a = ws.openTab(s());
    final b = ws.split(SplitDir.right, s());
    ws.split(SplitDir.down, s());
    ws.focus(a);
    ws.closePane(b);
    expect(ws.focused, a);
  });

  test("a tab goes with its last pane; closing a tab ends all its sessions", () {
    final a = ws.openTab(s());
    final b = ws.openTab(s());
    final c = ws.split(SplitDir.right, s());
    ws.closePane(a);
    expect(ws.tabs.length, 1);
    expect(ws.active, 0);
    expect(ws.focused, c);
    ws.closeTab(0);
    expect(ended, [a.session, b.session, c.session]);
    expect(ws.tabs, isEmpty);
    expect(ws.focused, isNull);
  });

  test('closing a tab before the active one keeps the active one', () {
    ws.openTab(s());
    ws.openTab(s());
    final c = ws.openTab(s());
    ws.closeTab(0);
    expect(ws.focused, c);
  });

  test('a divider stays within 10% and 90%', () {
    ws.openTab(s());
    ws.split(SplitDir.right, s());
    final sp = ws.tab!.root as PaneSplit;
    ws.setRatio(sp, 0.02);
    expect(sp.ratio, 0.1);
    ws.setRatio(sp, 2);
    expect(sp.ratio, 0.9);
    ws.setRatio(sp, 0.3);
    expect(ws.tab!.rects(const Rect.fromLTWH(0, 0, 100, 10)).values.first.width, closeTo(30, 1e-9));
  });

  test('closeAll ends every session', () {
    ws.openTab(s());
    ws.split(SplitDir.down, s());
    ws.openTab(s());
    ws.closeAll();
    expect(ended.length, 3);
    expect(ws.tabs, isEmpty);
  });
}
