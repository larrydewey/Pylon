// The Files page (SPEC 11) over an in-memory tree with the core's rules:
// browsing, cut and paste moving, copy and paste beside the original
// ("NAME copy"), nothing replaced, deleting after asking. Escaping names
// for display, and the framed protocol's results.
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/files.dart';
import 'package:pylon/backend/mem_files.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/theme.dart';
import 'package:pylon/ui/app_state.dart';
import 'package:pylon/ui/files_page.dart';

import 'fakes.dart';

Uint8List b(String s) => bytesOf(s);

void main() {
  late FakeBackend be;
  late AppState st;

  Future<MemFiles> open(WidgetTester tester) async {
    be = FakeBackend()
      ..tree = {
        '/home/demo/a.txt': b('alpha'),
        '/home/demo/docs/': null,
        '/home/demo/docs/old.txt': b('old'),
      };
    st = AppState(be);
    await st.load();
    await tester.pumpWidget(MaterialApp(theme: pylonTheme(), home: FilesPage(st: st, host: be.hosts[0])));
    await tester.pumpAndSettle();
    return be.files.last;
  }

  Future<void> more(WidgetTester tester, String name, String action) async {
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, name), matching: find.byTooltip('More')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  testWidgets('lists folders first, opens a folder, goes up', (tester) async {
    await open(tester);
    expect(find.text('/home/demo'), findsOneWidget);
    final docs = tester.getTopLeft(find.text('docs')).dy;
    final a = tester.getTopLeft(find.text('a.txt')).dy;
    expect(docs < a, true);
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    expect(find.text('/home/demo/docs'), findsOneWidget);
    expect(find.text('old.txt'), findsOneWidget);
    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(find.text('a.txt'), findsOneWidget);
  });

  testWidgets('cut, then paste in another folder, moves the file', (tester) async {
    final fs = await open(tester);
    await more(tester, 'a.txt', 'Cut');
    expect(st.clip?.cut, true);
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();
    expect(fs.fileAt('/home/demo/docs/a.txt'), b('alpha'));
    expect(fs.fileAt('/home/demo/a.txt'), isNull);
    expect(st.clip, isNull);
    expect(find.text('a.txt'), findsOneWidget);
  });

  testWidgets('copy, then paste beside the original, makes "NAME copy"', (tester) async {
    final fs = await open(tester);
    await more(tester, 'a.txt', 'Copy');
    await tester.tap(find.text('Paste here'));
    await tester.pumpAndSettle();
    expect(fs.fileAt('/home/demo/a copy.txt'), b('alpha'));
    // The marks stay: a second paste makes another copy.
    await tester.tap(find.text('Paste here'));
    await tester.pumpAndSettle();
    expect(fs.fileAt('/home/demo/a copy 2.txt'), b('alpha'));
    expect(fs.fileAt('/home/demo/a.txt'), b('alpha'));
  });

  testWidgets('a paste never replaces a file with the same name', (tester) async {
    final fs = await open(tester);
    fs.links.clear();
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    await more(tester, 'old.txt', 'Copy');
    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste here'));
    await tester.pumpAndSettle();
    expect(fs.fileAt('/home/demo/old.txt'), b('old'));
    // Pasted again into docs' parent: the name is taken now.
    await tester.tap(find.text('Paste here'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already exists; not replaced'), findsOneWidget);
    expect(fs.fileAt('/home/demo/old.txt'), b('old'));
  });

  testWidgets('select several, cut, and move them into a folder', (tester) async {
    final fs = await open(tester);
    await fs.makeDir(b('/home/demo/dest'));
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Cut'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('dest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();
    expect(fs.fileAt('/home/demo/dest/a.txt'), b('alpha'));
    expect(fs.fileAt('/home/demo/dest/docs/old.txt'), b('old'));
    expect(fs.dirAt('/home/demo/docs'), false);
  });

  testWidgets('rename refuses a taken name and a slash', (tester) async {
    final fs = await open(tester);
    await more(tester, 'a.txt', 'Rename');
    await tester.enterText(find.byType(TextField), 'x/y');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.text('A name cannot hold a slash.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'docs');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.textContaining('already exists; not replaced'), findsOneWidget);
    await more(tester, 'a.txt', 'Rename');
    await tester.enterText(find.byType(TextField), 'b.txt');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(fs.fileAt('/home/demo/b.txt'), b('alpha'));
  });

  testWidgets('delete asks first, and says folders go with their contents', (tester) async {
    final fs = await open(tester);
    await more(tester, 'docs', 'Delete');
    expect(find.textContaining('deleted with everything in them'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fs.dirAt('/home/demo/docs'), true);
    await more(tester, 'docs', 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(fs.dirAt('/home/demo/docs'), false);
    expect(fs.fileAt('/home/demo/docs/old.txt'), isNull);
  });

  test('names are shown escaped', () {
    expect(displayName(b('plain.txt')), 'plain.txt');
    expect(displayName(b('héllo')), 'héllo');
    expect(displayName([0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x72]), r'\x1b[31mr');
    expect(displayName([0x61, 0xff, 0x62]), r'a\xff' 'b');
    expect(displayName(b('a\u202Etxt.exe')), r'a\u{202e}txt.exe');
    expect(displayName(b('etc\u2215passwd')), r'etc\u{2215}passwd');
  });

  test('paths', () {
    expect(pathJoin(b('/a'), b('b')), b('/a/b'));
    expect(pathJoin(b('/'), b('b')), b('/b'));
    expect(baseName(b('/a/b/')), b('b'));
    expect(dirName(b('/a/b')), b('/a'));
    expect(dirName(b('/a')), b('/'));
    expect(badName('..'), isNotNull);
    expect(badName('ok name'), isNull);
  });

  test('the framed LIST and STAT results', () {
    final name = b('f');
    final entry = [...[0, 0, 0, 1], ...name, 0, ...[0, 0, 0, 0, 0, 0, 1, 0], ...[0, 0, 0x81, 0xa4], ...[0, 0, 0, 5]];
    final list = parseList(Uint8List.fromList([0, 0, 0, 1, ...entry]));
    expect(list.single.shown, 'f');
    expect(list.single.kind, FileKind.file);
    expect(list.single.size, 256);
    expect(list.single.mtime, 5);
    expect(parseStat(b('/x'), Uint8List.fromList([0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])), isNull);
    expect(request(5, [b('a'), b('bc')]), [5, 0, 0, 0, 1, 97, 0, 0, 0, 2, 98, 99]);
  });

  test('a host has one clipboard owner', () {
    final h = Host(name: 'h', user: 'u', address: 'a');
    final c = FileClip(h, true, [b('/x')]);
    expect(c.paths.single, b('/x'));
  });
}
