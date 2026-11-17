// A tap on the terminal brings the soft keyboard back after it was put
// away (Back, or the keyboard's own hide key), while the hidden text
// field still has the focus: asking for the focus again does nothing then.
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
}
