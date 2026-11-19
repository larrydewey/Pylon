import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backend/model.dart';
import '../backend/select.dart';
import '../term/keys.dart';
import '../theme.dart';
import 'widgets.dart';

/// What the clipboard prompt says of [text]: its length in characters and
/// its number of lines (a last newline ends a line, it does not start one).
(int chars, int lines) clipStats(String text) {
  if (text.isEmpty) return (0, 0);
  final newlines = '\n'.allMatches(text).length;
  return (text.runes.length, text.endsWith('\n') ? newlines : newlines + 1);
}

/// OSC 52: a program wants to write to the clipboard. Asked every time
/// (SPEC 12); never the other way round. One sheet a session at a time,
/// and the sheet shows all of the text it offers, which never changes
/// while it is up: "Allow" copies exactly what the principal read. Writes
/// that arrive while it is up don't stack (tmux copies again on every
/// drag): the latest of them waits, replacing any earlier one, and is
/// asked about, in a sheet of its own, when this one closes.
Future<void> askClipboard(BuildContext context, Session s) async {
  String? latest() {
    String? text;
    for (final req in s.clipboardRequests) {
      try {
        text = utf8.decode(base64.decode(String.fromCharCodes(req)), allowMalformed: true);
      } catch (_) {}
    }
    s.clipboardRequests.clear();
    return text;
  }

  final open = _asking[s];
  if (open != null) {
    final t = latest();
    if (t != null) open.value = t;
    return;
  }
  var next = latest();
  if (next == null) return;
  // The write waiting for the next sheet, if any.
  final waiting = ValueNotifier<String?>(null);
  _asking[s] = waiting;
  try {
    while (next != null) {
      if (!context.mounted) break;
      final text = next;
      waiting.value = null;
      final ok = await _clipSheet(context, s, text, waiting);
      if (ok == true) await copySensitive(text);
      next = waiting.value;
    }
  } finally {
    _asking.remove(s);
    waiting.dispose();
  }
}

final _asking = <Session, ValueNotifier<String?>>{};

Future<bool?> _clipSheet(BuildContext context, Session s, String text, ValueNotifier<String?> waiting) {
  final who = s.local ? 'the local shell' : s.host.name;
  final (chars, lines) = clipStats(text);
  final size = '$chars character${chars == 1 ? '' : 's'} · $lines line${lines == 1 ? '' : 's'}';
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: P.surface,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Let ${visible(who, oneLine: true)} copy to your clipboard?', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
              s.local
                  ? 'A program in the local shell wants to put this text on this device\'s clipboard. It can never read your clipboard.'
                  : 'A program on the server wants to put this text on this device\'s clipboard. Programs on a server can never read your clipboard.',
              style: const TextStyle(color: Color(0xFFC9D1DB))),
          const SizedBox(height: 10),
          Text(size, key: const Key('clip-size'), style: const TextStyle(fontSize: 12, color: P.muted)),
          const SizedBox(height: 6),
          // All of it, control and direction characters shown as codes.
          Flexible(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(color: P.ink2, borderRadius: BorderRadius.circular(10), border: Border.all(color: P.line)),
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  key: const Key('clip-scroll'),
                  padding: const EdgeInsets.all(10),
                  child: Text(visible(text), key: const Key('clip-offer'), style: const TextStyle(fontFamily: mono, fontSize: 12)),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: waiting,
            builder: (c, w, _) => w == null
                ? const SizedBox.shrink()
                : const Padding(
                    key: Key('clip-waiting'),
                    padding: EdgeInsets.only(top: 8),
                    child: Text('It has asked to copy something else since; you will be asked about that next.', style: TextStyle(fontSize: 12, color: P.muted)),
                  ),
          ),
          const SizedBox(height: 14),
          FilledButton(key: const Key('clip-allow'), onPressed: () => Navigator.pop(c, true), child: const Text('Allow this once')),
          TextButton(key: const Key('clip-deny'), onPressed: () => Navigator.pop(c, false), child: const Text("Don't allow")),
        ]),
      ),
    ),
  );
}


/// Asks before disconnecting a live session; true to go ahead. Says what
/// happens on the other end: an SSH shell ends with its connection, a
/// session pylond keeps does not, and the local shell ends.
Future<bool> confirmDisconnect(BuildContext context, Session s) async {
  final pylon = !s.local && s.host.mode == Mode.pylon;
  final who = s.local ? 'the local shell' : s.host.name;
  final what = s.local
      ? 'The local shell and everything running in it end.'
      : pylon
          ? 'pylond keeps the session on ${s.host.name}, running: connect again to resume it. To end it, exit its shell.'
          : 'The shell on ${s.host.name}, and what runs in it in the foreground, ends with the connection.';
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: P.surface,
    builder: (c) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.local ? 'End the local shell?' : 'Disconnect from $who?', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(what, style: const TextStyle(color: Color(0xFFC9D1DB), height: 1.4)),
        const SizedBox(height: 14),
        FilledButton(
          key: const Key('disconnect-ok'),
          style: FilledButton.styleFrom(backgroundColor: P.redLine, foregroundColor: P.text),
          onPressed: () => Navigator.pop(c, true),
          child: Text(s.local ? 'End it' : 'Disconnect'),
        ),
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
      ]),
    ),
  );
  return ok == true;
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
