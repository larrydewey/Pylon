// The Linux desktop layout (SPEC 15): tabs, splits, shortcuts, focus and
// the size each pane's session is given.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/desktop/desktop_shell.dart';
import 'package:pylon/desktop/layout.dart';
import 'package:pylon/theme.dart';
import 'package:pylon/ui/app_state.dart';

import 'fakes.dart';

void main() {
  late FakeBackend be;
  late AppState st;

  Future<DesktopShellState> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    be = FakeBackend();
    st = AppState(be);
    await st.load();
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: DesktopShell(st: st)));
    await tester.pumpAndSettle();
    return tester.state<DesktopShellState>(find.byType(DesktopShell));
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey k, {bool shift = true}) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(k);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('no tab: the hosts and the local shell to open', (tester) async {
    await pumpShell(tester);
    expect(find.text('No terminals open'), findsOneWidget);
    expect(find.text('Local shell'), findsOneWidget);
    expect(find.text('build-01'), findsOneWidget);
    await tester.tap(find.text('build-01'));
    await tester.pumpAndSettle();
    expect(be.opened.single.host.name, 'build-01');
    expect(find.textContaining('build-01 · SSH'), findsOneWidget);
  });

  testWidgets('Ctrl+Shift+L opens the local shell in a tab, sized to the window', (tester) async {
    final shell = await pumpShell(tester);
    await chord(tester, LogicalKeyboardKey.keyL);
    expect(shell.ws.tabs.length, 1);
    final s = be.opened.single;
    expect(s.local, true);
    expect(s.sizes, isNotEmpty);
    expect(s.sizes.last.$2, greaterThan(80), reason: 'a 1400-pixel window is wider than 80 columns');
    expect(find.textContaining('local · this computer'), findsOneWidget);
    expect(find.text("Can't reach Pylon's files, agent or sessions"), findsOneWidget);
  });

  testWidgets('splits: a new session per pane, each resized to its pane; typing goes to the focused one', (tester) async {
    final shell = await pumpShell(tester);
    shell.open(st.hosts.first);
    await tester.pumpAndSettle();
    final a = be.opened[0];
    final full = a.sizes.last;

    await chord(tester, LogicalKeyboardKey.keyE); // split right, same host
    expect(be.opened.length, 2);
    final b = be.opened[1];
    expect(b.host, same(a.host));
    expect(a.sizes.last.$2, lessThan(full.$2 ~/ 2 + 2), reason: 'the first pane now has half the width');
    expect(b.sizes.last.$2, lessThan(full.$2 ~/ 2 + 2));
    expect(a.sizes.last.$1, full.$1, reason: 'and all its height');
    expect(shell.ws.focused!.session, b);

    await chord(tester, LogicalKeyboardKey.keyO); // split down
    final c = be.opened[2];
    expect(c.sizes.last.$1, lessThan(full.$1 ~/ 2 + 1));
    expect(c.sizes.last.$2, b.sizes.last.$2);

    tester.testTextInput.enterText('x');
    await tester.pump();
    expect(c.inputs.expand((e) => e).toList(), [120]);
    expect(a.inputs, isEmpty);

    await chord(tester, LogicalKeyboardKey.arrowLeft);
    expect(shell.ws.focused!.session, a);
    tester.testTextInput.enterText('y');
    await tester.pump();
    expect(a.inputs.expand((e) => e).toList(), [121]);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(a.inputs.last, [13], reason: 'Enter reaches the focused session');
    expect(find.text('build-01 · 3 panes'), findsOneWidget);
  });

  testWidgets('Ctrl+Shift+W closes the focused pane and ends its session; the tab goes with its last', (tester) async {
    final shell = await pumpShell(tester);
    shell.open(st.hosts.first);
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyE);
    final a = be.opened[0], b = be.opened[1];
    final half = a.sizes.last;
    await chord(tester, LogicalKeyboardKey.keyW);
    expect(b.closed, true);
    expect(a.closed, false);
    expect(st.sessions, [a]);
    expect(a.sizes.last.$2, greaterThan(half.$2), reason: 'the remaining pane takes the whole width again');
    await chord(tester, LogicalKeyboardKey.keyW);
    expect(a.closed, true);
    expect(shell.ws.tabs, isEmpty);
    expect(find.text('No terminals open'), findsOneWidget);
  });

  testWidgets('tabs: Ctrl+PageDown cycles, closing a tab ends its sessions, a dragged divider resizes', (tester) async {
    final shell = await pumpShell(tester);
    shell.open(st.hosts.first);
    shell.open(st.hosts.last);
    await tester.pumpAndSettle();
    expect(shell.ws.active, 1);
    expect(find.text('● prod-db'), findsOneWidget, reason: 'production hosts are marked');
    await chord(tester, LogicalKeyboardKey.pageDown, shift: false);
    expect(shell.ws.active, 0);

    shell.open(st.hosts.first, where: SplitDir.right);
    await tester.pumpAndSettle();
    final left = be.opened[0];
    final before = left.sizes.last.$2;
    await tester.drag(find.byType(SplitView).first, const Offset(0, 0)); // a no-op drag settles hit testing
    final divider = tester.getCenter(find.byType(SplitView).first);
    await tester.dragFrom(Offset(divider.dx, divider.dy), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(left.sizes.last.$2, greaterThan(before), reason: 'dragging the divider right widens the left pane');

    shell.ws.closeTab(0);
    await tester.pumpAndSettle();
    expect(be.opened[0].closed && be.opened[2].closed, true);
    expect(be.opened[1].closed, false);
  });
}
