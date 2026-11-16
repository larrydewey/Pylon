import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backend/model.dart';
import '../term/keys.dart';
import '../theme.dart';
import 'widgets.dart';

/// OSC 52: a program wants to write to the clipboard. Asked every time
/// (SPEC 12); never the other way round. Takes the oldest request.
Future<void> askClipboard(BuildContext context, Session s) async {
  if (s.clipboardRequests.isEmpty) return;
  final req = s.clipboardRequests.removeAt(0);
  String text;
  try {
    text = utf8.decode(base64.decode(String.fromCharCodes(req)), allowMalformed: true);
  } catch (_) {
    return;
  }
  final who = s.local ? 'The local shell' : s.host.name;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: P.surface,
    builder: (c) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.local ? 'Let the local shell copy to your clipboard?' : 'Let $who copy to your clipboard?', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
            s.local
                ? 'A program in the local shell wants to put ${text.length} characters on this device\'s clipboard. It can never read your clipboard.'
                : 'A program on the server wants to put ${text.length} characters on this device\'s clipboard. Programs on a server can never read your clipboard.',
            style: const TextStyle(color: Color(0xFFC9D1DB))),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: P.ink2, borderRadius: BorderRadius.circular(10), border: Border.all(color: P.line)),
          child: Text(visible(text.length > 300 ? '${text.substring(0, 300)}…' : text), style: const TextStyle(fontFamily: mono, fontSize: 12)),
        ),
        const SizedBox(height: 14),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Allow this once')),
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("Don't allow")),
      ]),
    ),
  );
  if (ok == true) await Clipboard.setData(ClipboardData(text: text));
}

/// A paste from the clipboard, shown for confirmation first when it holds
/// lines or control characters and the program did not ask for a
/// bracketed paste (SPEC 12).
Future<void> pasteInto(BuildContext context, Session s) async {
  final d = await Clipboard.getData(Clipboard.kTextPlain);
  final t = d?.text ?? '';
  if (t.isEmpty) return;
  final bracketed = s.screen.bracketedPaste;
  if (KeyEncoder.pasteNeedsConfirm(t, bracketed: bracketed)) {
    if (!context.mounted) return;
    final lines = '\n'.allMatches(t).length + 1;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: P.surface,
      builder: (c) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Paste $lines lines into the shell?', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text("The program running isn't expecting a paste, so each line would run as a command as soon as it arrives.", style: TextStyle(color: Color(0xFFC9D1DB))),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: P.ink2, borderRadius: BorderRadius.circular(10), border: Border.all(color: P.line)),
            child: Text(visible(t.length > 600 ? '${t.substring(0, 600)}…' : t), style: const TextStyle(fontFamily: mono, fontSize: 12)),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text('Paste $lines lines')),
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        ]),
      ),
    );
    if (ok != true) return;
  }
  s.input(KeyEncoder.paste(t, bracketed: bracketed));
}
