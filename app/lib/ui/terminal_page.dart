import 'dart:async';

import 'package:flutter/material.dart';

import '../backend/model.dart';
import '../backend/select.dart';
import '../term/term_view.dart';
import '../theme.dart';
import 'app_state.dart';
import 'prompts.dart';
import 'session_page.dart';
import 'widgets.dart';

/// One terminal, full screen (phones and tablets). For the local shell
/// ([Host.local]) it is drawn in purple, "this device", with what the
/// sandbox keeps out stated under the terminal (SPEC 13).
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

  bool get local => widget.host.local;

  @override
  void initState() {
    super.initState();
    s = widget.st.open(widget.host, 24, 80);
    sub = s.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      askClipboard(context, s);
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
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
                backgroundColor: latched ? (local ? P.purpleLine : P.tealDeep) : (local ? P.localKey : P.surface),
                side: BorderSide(color: latched ? (local ? P.purple : P.tealLine) : (local ? P.purpleLine : P.line)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: onTap ??
                  () {
                    s.input(bytes);
                    view.currentState?.focus();
                  },
              child: Text(label, style: TextStyle(fontFamily: mono, fontSize: 13, color: latched ? (local ? P.purple : P.tealText) : (local ? P.localText : P.text))),
            ),
          ),
        ),
      );

  Widget _title() {
    final h = widget.host;
    final ended = s.exitCode != null;
    if (local) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Local shell · $deviceName', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: P.localText)),
        Text(ended ? 'Ended (${s.exitCode})' : 'Sandboxed · no network to your hosts · no keys', style: const TextStyle(fontSize: 12, color: P.localMuted)),
      ]);
    }
    return InkWell(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SessionPage(st: widget.st, host: h))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.title.isNotEmpty ? visible(s.title) : h.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        Row(children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: ended ? P.red : P.teal, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(ended ? 'Ended (${s.exitCode})' : (h.mode == Mode.pylon ? 'Pylon · post-quantum · roaming' : 'SSH · pinned host key'), style: const TextStyle(fontSize: 12, color: P.muted)),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      backgroundColor: local ? P.localInk : P.ink2,
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: local ? P.purpleDeep : P.ink,
        foregroundColor: local ? P.localText : P.text,
        shape: local ? const Border(bottom: BorderSide(color: P.purpleLine)) : null,
        title: _title(),
        actions: [
          IconButton(tooltip: 'Paste', icon: const Icon(Icons.content_paste), onPressed: () => pasteInto(context, s)),
          if (local && s.exitCode == null)
            IconButton(
              tooltip: 'End the local shell',
              icon: const Icon(Icons.close),
              onPressed: () {
                widget.st.end(s);
                Navigator.pop(context);
              },
            ),
        ],
      ),
      body: Column(children: [
        if (s.agentKeys == AgentKeys.none || s.agentKeys == AgentKeys.unreachable) _KeysCard(session: s),
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
            cursor: local ? P.purple : P.teal,
            onModsUsed: () => setState(() => ctrl = alt = false),
            onInput: s.input,
            onResize: s.resize,
          ),
        ),
        if (local) const LocalNote(),
        Container(
          decoration: BoxDecoration(color: local ? P.purpleDeep : P.ink, border: local ? const Border(top: BorderSide(color: P.purpleLine)) : null),
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
    // The local shell's frame: purple all round, "this device".
    return local ? DecoratedBox(position: DecorationPosition.foreground, decoration: BoxDecoration(border: Border.all(color: P.purpleLine, width: 3)), child: page) : page;
  }
}

/// What the local shell's sandbox keeps out, under its terminal.
class LocalNote extends StatelessWidget {
  const LocalNote({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: P.purpleDeep, borderRadius: BorderRadius.circular(12), border: Border.all(color: P.purpleLine)),
        child: Text(
          desktopLayout
              ? 'A sandbox of its own: its own home directory, no network, nothing of Pylon\'s files, agent or sessions. Purple always means "this computer", never a server.'
              : 'A separate sandbox with its own user ID: it can\'t see Pylon\'s hosts, keys, sessions or Symbolon, and has no network or storage. Purple always means "this phone", never a server.',
          style: const TextStyle(fontSize: 12, height: 1.5, color: P.localMuted),
        ),
      );
}

/// Symbolon has no SSH key to offer, or Pylon cannot reach it: what to do
/// there, and a way to get there, in place of a bare refusal.
class _KeysCard extends StatelessWidget {
  const _KeysCard({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final none = session.agentKeys == AgentKeys.none;
    final host = session.host.address;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: P.amberDeep, borderRadius: BorderRadius.circular(12), border: Border.all(color: P.amberLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(none ? 'Symbolon has no SSH key yet' : 'Pylon cannot reach Symbolon',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: P.amber)),
        const SizedBox(height: 8),
        Text(
          none
              ? '1. In Symbolon, open SSH keys and make a key (or import one).\n'
                  '2. Add its public key to ~/.ssh/authorized_keys on $host.\n'
                  '3. Come back and connect again. Symbolon asks you before it signs.'
              : 'Symbolon holds the keys Pylon signs in with. Install Symbolon, or if it is '
                  'installed, install Pylon again after it: Android grants Pylon access to '
                  'Symbolon only when Symbolon is already there.',
          style: const TextStyle(fontSize: 13, height: 1.4, color: P.text),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('open-symbolon'),
          icon: const Icon(Icons.vpn_key_outlined, size: 18),
          label: Text(none ? 'Open SSH keys in Symbolon' : 'Open Symbolon'),
          onPressed: () async {
            final ok = await openKeyHolder();
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Symbolon is not installed on this phone.')));
            }
          },
        ),
      ]),
    );
  }
}
