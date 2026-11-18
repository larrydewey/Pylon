// The soft keyboard around the terminal. A tap brings it back after it
// was put away (Back, or its own hide key) while the hidden text field
// still has the focus, and Enter sends a carriage return without putting
// the keyboard away.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/term/screen.dart';
import 'package:pylon/term/term_view.dart';
import 'package:pylon/theme.dart';

void main() {
  testWidgets('a tap shows the keyboard again after it was hidden', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: pylonTheme(),
      home: Scaffold(body: SizedBox(width: 400, height: 400, child: TermView(screen: Screen.blank(24, 80), onInput: (_) {}, onResize: (_, _) {}))),
    ));
    await tester.tap(find.byType(TermView));
    await tester.pump();
    expect(tester.testTextInput.isVisible, true);

    // The person puts the keyboard away; the field keeps the focus.
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    await tester.pump();
    expect(tester.testTextInput.isVisible, false);
    expect(tester.state<TermViewState>(find.byType(TermView)).hasFocus || FocusManager.instance.primaryFocus != null, true);

    await tester.tap(find.byType(TermView));
    await tester.pump();
    expect(tester.testTextInput.isVisible, true);
  });

  testWidgets('Enter sends a carriage return and keeps the keyboard up', (tester) async {
    final sent = <List<int>>[];
    await tester.pumpWidget(MaterialApp(
      theme: pylonTheme(),
      home: Scaffold(body: SizedBox(width: 400, height: 400, child: TermView(screen: Screen.blank(24, 80), onInput: sent.add, onResize: (_, _) {}))),
    ));
    await tester.tap(find.byType(TermView));
    await tester.pump();
    expect(tester.testTextInput.isVisible, true);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sent.last, [13]);
    expect(tester.testTextInput.isVisible, true);
    expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, true);

    // A second Enter still reaches the host.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sent.where((b) => b.length == 1 && b[0] == 13).length, 2);
  });
}
