// Ending sessions: disconnecting a live one (asked first), closing an
// ended one, and clearing the ended ones from the sessions page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/theme.dart';
import 'package:pylon/ui/app_state.dart';
import 'package:pylon/ui/session_note.dart';
import 'package:pylon/ui/sessions_page.dart';
import 'package:pylon/ui/terminal_page.dart';

import 'fakes.dart';

Widget sessions(AppState st) => MaterialApp(theme: pylonTheme(), home: Scaffold(body: SessionsPage(st: st)));

void main() {
  testWidgets('a live session is disconnected from the sessions page, after asking', (tester) async {
    final be = FakeBackend();
    final st = AppState(be);
    await st.load();
    final s = st.open(be.hosts[0], 24, 80) as FakeSession;
    await tester.pumpWidget(sessions(st));
    expect(find.text('build-01'), findsOneWidget);

    // Cancelled: still live.
    await tester.tap(find.byKey(const Key('disconnect-build-01')));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect from build-01?'), findsOneWidget);
    expect(find.textContaining('ends with the connection'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(s.closed, false);
    expect(st.live, [s]);

    await tester.tap(find.byKey(const Key('disconnect-build-01')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('disconnect-ok')));
    await tester.pumpAndSettle();
    expect(s.closed, true);
    expect(st.sessions, isEmpty);
    expect(find.text('No live sessions.'), findsOneWidget);
  });

  testWidgets('a Pylon session is said to stay on the server', (tester) async {
    final st = AppState(FakeBackend());
    st.open(Host(name: 'roam', user: 'u', address: '10.0.0.9', mode: Mode.pylon), 24, 80);
    await tester.pumpWidget(sessions(st));
    await tester.tap(find.byKey(const Key('disconnect-roam')));
    await tester.pumpAndSettle();
    expect(find.textContaining('pylond keeps the session on roam'), findsOneWidget);
  });

  testWidgets('ended sessions are listed with how they ended, and cleared', (tester) async {
    final be = FakeBackend();
    final st = AppState(be);
    await st.load();
    final a = st.open(be.hosts[0], 24, 80);
    final b = st.open(be.hosts[1], 24, 80);
    a.status = 'pylon: the server accepted none of the agent\'s keys';
    a.exitCode = 1;
    b.exitCode = 0;
    a.changed();
    b.changed();
    await tester.pumpWidget(sessions(st));
    expect(find.text('ENDED'), findsOneWidget);
    expect(find.text('pylon: the server accepted none of the agent\'s keys'), findsOneWidget);
    expect(find.text('Ended (0)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove-build-01')));
    await tester.pumpAndSettle();
    expect(st.sessions, [b]);

    await tester.tap(find.byKey(const Key('clear-ended')));
    await tester.pumpAndSettle();
    expect(st.sessions, isEmpty);
    expect(find.text('ENDED'), findsNothing);
  });

  testWidgets('the terminal page disconnects a live session and closes an ended one', (tester) async {
    final be = FakeBackend();
    final st = AppState(be);
    await st.load();
    final h = be.hosts[0];
    await tester.pumpWidget(MaterialApp(
      theme: pylonTheme(),
      home: Builder(
        builder: (c) => TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => TerminalPage(st: st, host: h))), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final s = be.opened.single;
    await tester.tap(find.byKey(const Key('disconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('disconnect-ok')));
    await tester.pumpAndSettle();
    expect(s.closed, true);
    expect(st.sessions, isEmpty);
    expect(find.byType(TerminalPage), findsNothing);

    // Ended on its own: closing it asks nothing.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final t = be.opened.last;
    t.exitCode = 255;
    t.changed();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('disconnect')), findsNothing);
    await tester.tap(find.byKey(const Key('close-ended')));
    await tester.pumpAndSettle();
    expect(st.sessions, isEmpty);
    expect(find.byType(TerminalPage), findsNothing);
  });

  testWidgets("a live session's connection details fold to one line; an ended one's show whole", (tester) async {
    final s = FakeSession(Host(name: 'roam', user: 'u', address: '10.0.0.9', mode: Mode.pylon));
    s.status = 'pylon: pylond 0.2.1 (release 9): signed by 3 release keys, entry 8 of the log\'s 9\n'
        'pylon: Pylon protocol session to 10.0.0.9:51000 (experimental); SSH closed\n';
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: Scaffold(body: SessionNote(session: s))));
    String shown() => tester.widget<Text>(find.byKey(const Key('session-note'))).data!;
    expect(shown(), startsWith('pylon: pylond 0.2.1'));
    expect(shown(), isNot(contains('SSH closed')));
    expect(find.text('+1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-note-toggle')));
    await tester.pump();
    expect(shown(), contains('SSH closed'));
    expect(find.text('+1'), findsNothing);

    await tester.tap(find.byKey(const Key('session-note-toggle')));
    await tester.pump();
    expect(shown(), isNot(contains('SSH closed')));

    // Ended: the reason is the point, whole and not foldable.
    s.status = 'pylon: the connection closed while sending\npylon: (more)';
    s.exitCode = 1;
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: Scaffold(body: SessionNote(key: const Key('ended'), session: s))));
    expect(shown(), contains('(more)'));
    expect(find.byKey(const Key('session-note-toggle')), findsNothing);
  });
}
