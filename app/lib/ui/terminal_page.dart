import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backend/model.dart';
import '../term/keys.dart';
import '../term/term_view.dart';
import '../theme.dart';
import 'app_state.dart';
import 'session_page.dart';
import 'widgets.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.st, required this.host});
  final AppState st;
  final Host host;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  late Session s;
  StreamSubscription<void>? sub;
  final view = GlobalKey<TermViewState>();
  bool ctrl = false, alt = false;

  @override
  void initState() {
    super.initState();
    s = widget.st.open(widget.host, 24, 80);
    sub = s.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      _clipboard();
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  // OSC 52: a program on the host wants to write to the clipboard. Asked
  // every time (SPEC 12); never the other way round.
  Future<void> _clipboard() async {
    if (s.clipboardRequests.isEmpty) return;
    final req = s.clipboardRequests.removeAt(0);
    String text;
    try {
      text = utf8.decode(base64.decode(String.fromCharCodes(req)), allowMalformed: true);
    } catch (_) {
      return;
    }
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: P.surface,
      builder: (c) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Let ${widget.host.name} copy to your clipboard?', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('A program on the server wants to put ${text.length} characters on this device\'s clipboard. Programs on a server can never read your clipboard.', style: const TextStyle(color: Color(0xFFC9D1DB))),
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

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text ?? '';
    if (t.isEmpty) return;
    final bracketed = s.screen.bracketedPaste;
    if (KeyEncoder.pasteNeedsConfirm(t, bracketed: bracketed)) {
      if (!mounted) return;
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

  Widget _key(String label, List<int> bytes, {bool latched = false, VoidCallback? onTap}) => Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: SizedBox(
            height: 44,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 44),
                backgroundColor: latched ? P.tealDeep : P.surface,
                side: BorderSide(color: latched ? P.tealLine : P.line),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: onTap ?? () {
                s.input(bytes);
                view.currentState?.focus();
              },
              child: Text(label, style: TextStyle(fontFamily: mono, fontSize: 13, color: latched ? P.tealText : P.text)),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    final ended = s.exitCode != null;
    return Scaffold(
      backgroundColor: P.ink2,
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionPage(st: widget.st, host: h))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.title.isNotEmpty ? visible(s.title) : h.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Row(children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: ended ? P.red : P.teal, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(ended ? 'Ended (${s.exitCode})' : (h.mode == Mode.pylon ? 'Pylon · post-quantum · roaming' : 'SSH · pinned host key'), style: const TextStyle(fontSize: 12, color: P.muted)),
            ]),
          ]),
        ),
        actions: [IconButton(tooltip: 'Paste', icon: const Icon(Icons.content_paste), onPressed: _paste)],
      ),
      body: Column(children: [
        if (s.status.trim().isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: s.exitCode != null ? P.redDeep : P.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: s.exitCode != null ? P.redLine : P.line)),
            child: Text(visible(s.status.trim()), style: const TextStyle(fontSize: 13, color: Color(0xFFE6CFCF))),
          ),
        Expanded(
          child: TermView(
            key: view,
            screen: s.screen,
            ctrl: ctrl,
            alt: alt,
            onModsUsed: () => setState(() => ctrl = alt = false),
            onInput: s.input,
            onResize: s.resize,
          ),
        ),
        Container(
          color: P.ink,
          padding: const EdgeInsets.fromLTRB(5, 4, 5, 8),
          child: Row(children: [
            _key('Esc', [27]),
            _key('Tab', [9]),
            _key('Ctrl', [], latched: ctrl, onTap: () => setState(() => ctrl = !ctrl)),
            _key('Alt', [], latched: alt, onTap: () => setState(() => alt = !alt)),
            _key('←', s.screen.appCursor ? [27, 79, 68] : [27, 91, 68]),
            _key('↑', s.screen.appCursor ? [27, 79, 65] : [27, 91, 65]),
            _key('↓', s.screen.appCursor ? [27, 79, 66] : [27, 91, 66]),
            _key('→', s.screen.appCursor ? [27, 79, 67] : [27, 91, 67]),
          ]),
        ),
      ]),
    );
  }
}
