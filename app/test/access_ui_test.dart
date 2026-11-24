// Getting into a server, in the interface: the card a refusal shows, the
// Authorize a key page, Share pin, and the explainer a new host leads to.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pylon/backend/access.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/theme.dart';
import 'package:pylon/ui/app_state.dart';
import 'package:pylon/ui/authorize_page.dart';
import 'package:pylon/ui/host_edit_page.dart';
import 'package:pylon/ui/pin_page.dart';
import 'package:pylon/ui/session_note.dart';

import 'access_test.dart' show ecdsa, ed, refusal;
import 'fakes.dart';

Widget page(Widget w) => MaterialApp(theme: pylonTheme(), home: w);

/// What the app put on the clipboard, newest last.
List<String> clipboard(WidgetTester tester) {
  final got = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') got.add((call.arguments as Map)['text'] as String);
    return null;
  });
  return got;
}

void main() {
  testWidgets('a refusal shows the keys and the command to copy, the message folded away', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    final copied = clipboard(tester);
    final st = AppState(FakeBackend());
    final s = FakeSession(Host(name: 'nas', user: 'larry', address: 'nas.lan', port: 2222))
      ..status = refusal
      ..exitCode = 1;
    await tester.pumpWidget(page(Scaffold(body: Column(children: [SessionNote(session: s, st: st)]))));

    expect(find.byKey(const Key('key-refusal')), findsOneWidget);
    expect(find.text("larry@nas.lan refused this device's key"), findsOneWidget);
    expect(find.textContaining('Symbolon quorum'), findsOneWidget);
    expect(find.text(ecdsa), findsOneWidget);
    expect(find.text(ed), findsOneWidget);
    expect(find.textContaining('certificate was offered'), findsOneWidget);
    expect(find.text("pylon authorize -p 2222 larry@nas.lan '$ecdsa'"), findsOneWidget);
    expect(find.text(modesFix), findsOneWidget);
    // The core's own words: folded until asked for.
    expect(find.byKey(const Key('key-refusal-text')), findsNothing);
    expect(find.byKey(const Key('session-note')), findsNothing);

    await tester.ensureVisible(find.byTooltip('Copy').first);
    await tester.tap(find.byTooltip('Copy').first);
    await tester.pump();
    expect(copied, [ecdsa]);

    await tester.ensureVisible(find.byKey(const Key('key-refusal-raw')));
    await tester.tap(find.byKey(const Key('key-refusal-raw')));
    await tester.pump();
    expect(find.byKey(const Key('key-refusal-text')), findsOneWidget);
  });

  testWidgets('other messages stay a plain note', (tester) async {
    final s = FakeSession(Host(name: 'nas', user: 'larry', address: 'nas.lan'))
      ..status = 'pylon: connection refused'
      ..exitCode = 1;
    await tester.pumpWidget(page(Scaffold(body: Column(children: [SessionNote(session: s)]))));
    expect(find.byKey(const Key('key-refusal')), findsNothing);
    expect(find.text('pylon: connection refused'), findsOneWidget);
  });

  testWidgets('Authorize a key: checked before it runs, then the report', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    final be = FakeBackend();
    final st = AppState(be);
    await st.load();
    await tester.pumpWidget(page(AuthorizePage(st: st, host: be.hosts[0])));

    final run = find.byKey(const Key('authorize-run'));
    expect(tester.widget<FilledButton>(run).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('authorize-keys')), '$ed\nnot a key');
    await tester.pump();
    expect(find.textContaining('Line 2:'), findsOneWidget);
    expect(tester.widget<FilledButton>(run).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('authorize-keys')), '$ed\n$ecdsa\n');
    await tester.pump();
    expect(find.text('2 keys to add.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('authorize-ca')));
    await tester.tap(find.byKey(const Key('authorize-ca')));
    await tester.pump();
    await tester.ensureVisible(run);
    await tester.tap(run);
    await tester.pump();
    final a = be.authorized.single;
    expect(a.keys, [ed, ecdsa]);
    expect(a.ca, true);
    expect(find.text('Logging in to build-01…'), findsOneWidget);

    a.finish(true, report: [parseReportLine('added ssh-ed25519 SHA256:abc alice@laptop'), parseReportLine('present ecdsa-sha2-nistp256 SHA256:def'), parseReportLine('fixed ~/.ssh was 755, now 700'), parseReportLine('done')]);
    await tester.pump();
    expect(find.textContaining('Added'), findsOneWidget);
    expect(find.textContaining('Already there'), findsOneWidget);
    expect(find.textContaining('~/.ssh was 755, now 700'), findsOneWidget);
    expect(find.text('Authorize'), findsOneWidget);
  });

  testWidgets("Authorize a key: this device's keys, and a refusal of them", (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    final be = FakeBackend();
    final st = AppState(be);
    await st.load();
    await tester.pumpWidget(page(AuthorizePage(st: st, host: be.hosts[0])));
    await tester.tap(find.text("This device's keys"));
    await tester.pump();
    expect(find.byKey(const Key('authorize-keys')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('authorize-run')));
    await tester.tap(find.byKey(const Key('authorize-run')));
    await tester.pump();
    final a = be.authorized.single;
    expect(a.keys, isEmpty);
    expect(a.ca, false);

    a.finish(false, messages: refusal);
    await tester.pump();
    expect(find.byKey(const Key('key-refusal')), findsOneWidget);
  });

  testWidgets('a pinned host shares its pin as a code and as text', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    final be = FakeBackend();
    final st = AppState(be);
    await st.load();
    st.pinList = [Pin('10.0.8.21:22', 'ssh-ed25519', 'SHA256:x', '', '')];
    await tester.pumpWidget(page(HostEditPage(st: st, host: be.hosts[0])));
    expect(find.byKey(const Key('edit-authorize')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('share-pin')));
    await tester.tap(find.byKey(const Key('share-pin')));
    await tester.pumpAndSettle();
    expect(find.text('pylon-hostkey/1 10.0.8.21 SHA256:x'), findsOneWidget);
    expect(find.bySemanticsLabel('QR code'), findsOneWidget);
  });

  testWidgets('an unpinned host offers to pin it; a new host leads to the steps', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    final be = FakeBackend();
    final st = AppState(be);
    await st.load();
    st.pinList = [];
    await tester.pumpWidget(page(HostEditPage(st: st, host: be.hosts[0])));
    expect(find.byKey(const Key('share-pin')), findsNothing);
    expect(find.byKey(const Key('edit-pin')), findsOneWidget);

    await tester.pumpWidget(page(HostEditPage(st: st)));
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'nas');
    await tester.enterText(find.widgetWithText(TextField, 'User'), 'larry');
    await tester.enterText(find.widgetWithText(TextField, 'Address'), 'nas.lan');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Getting access to a server'), findsOneWidget);
    expect(find.byKey(const Key('access-pin')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('access-authorize')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('access-authorize')), findsOneWidget);
  });

  testWidgets('no camera here: the pin page has no Scan button, and says how to get a pin', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    addTearDown(tester.view.reset);
    final be = FakeBackend();
    final st = AppState(be);
    await tester.pumpWidget(page(PinPage(st: st, host: be.hosts[0])));
    expect(find.byKey(const Key('pin-scan')), findsNothing);
    expect(find.text('pylon share 10.0.8.21'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('trusts nothing by itself'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('trusts nothing by itself'), findsOneWidget);
  });
}
