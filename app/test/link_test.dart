// The Pylon protocol's link as the app shows it (SPEC 9.8): reconnecting,
// reconnected, and once the link is gone, reconnecting to the same shell.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/theme.dart';
import 'package:pylon/ui/app_state.dart';
import 'package:pylon/ui/sessions_page.dart';
import 'package:pylon/ui/terminal_page.dart';

import 'fakes.dart';

Host roam() => Host(name: 'roam', user: 'u', address: '10.0.0.9', mode: Mode.pylon);

Future<(FakeBackend, AppState, Host)> page(WidgetTester tester) async {
  final be = FakeBackend();
  final h = roam();
  be.hosts.add(h);
  final st = AppState(be);
  await st.load();
  await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: TerminalPage(st: st, host: h)));
  await tester.pump();
  return (be, st, h);
}

String header(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('header-state'))).data!;

void main() {
  testWidgets('a quiet link says so, and that the shell keeps running; back, it says that', (tester) async {
    final (be, st, _) = await page(tester);
    final s = be.opened.single;
    expect(header(tester), 'Pylon · post-quantum · roaming');
    expect(find.byKey(const Key('link-note')), findsNothing);

    s.linkState = linkReconnecting;
    s.linkNote = 'No answer from the host for 18 s; reconnecting.';
    s.changed();
    await tester.pump();
    await tester.pump();
    expect(header(tester), 'Reconnecting…');
    expect(find.textContaining('No answer from the host for 18 s; reconnecting.'), findsOneWidget);
    expect(find.textContaining('Your shell keeps running on the host'), findsOneWidget);

    // The sessions page says it too.
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: Scaffold(body: SessionsPage(st: st))));
    expect(find.text('Reconnecting…'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: TerminalPage(st: st, host: s.host)));
    s.linkState = linkConnected;
    s.linkNote = 'Reconnected after 4 min 2 s without an answer.';
    s.changed();
    await tester.pump();
    await tester.pump();
    expect(header(tester), 'Pylon · post-quantum · roaming');
    expect(find.textContaining('Reconnected after 4 min 2 s'), findsOneWidget);
    expect(find.textContaining('Your shell keeps running'), findsNothing);
  });

  testWidgets('a link that is gone reconnects to the same shell', (tester) async {
    final (be, _, _) = await page(tester);
    final s = be.opened.single;
    s.keptSession = 7;
    s.linkState = linkGone;
    s.status = 'pylon: Nothing heard from the host for 15 min 0 s, so pylond has let this connection go.';
    s.exitCode = 255;
    s.changed();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Your shell is still running on roam (session 7)'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reconnect')));
    await tester.pump();
    await tester.pump();
    expect(be.attached, [null, 7], reason: 'the second connection picks up session 7');
    expect(be.opened.length, 2);
    expect(s.closed, true);
    expect(header(tester), 'Pylon · post-quantum · roaming');
  });

  testWidgets('a shell that ended connects again to a new one', (tester) async {
    final (be, _, _) = await page(tester);
    final s = be.opened.single;
    s.keptSession = 7;
    s.exitCode = 0;
    s.changed();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('still running'), findsNothing);
    await tester.tap(find.byKey(const Key('reconnect')));
    await tester.pump();
    await tester.pump();
    expect(be.attached, [null, null]);
  });
}
