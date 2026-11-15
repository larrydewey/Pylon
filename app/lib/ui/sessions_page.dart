import 'package:flutter/material.dart';

import '../backend/model.dart';
import '../theme.dart';
import 'app_state.dart';
import 'terminal_page.dart';
import 'widgets.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key, required this.st});
  final AppState st;

  @override
  Widget build(BuildContext context) {
    final live = st.sessions.entries.where((e) => e.value.exitCode == null).toList();
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 16, 12, 24), children: [
        const Padding(padding: EdgeInsets.only(left: 8), child: Text('Sessions', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
        const Section('On this device'),
        if (live.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No live sessions.', style: TextStyle(color: P.muted))),
        for (final e in live)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card2(
              border: P.tealLine,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TerminalPage(st: st, host: e.key))),
              child: Row(children: [
                Expanded(child: Text(e.value.title.isNotEmpty ? visible(e.value.title) : e.key.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                Chip2(e.key.mode == Mode.pylon ? 'Pylon · live' : 'SSH · live'),
              ]),
            ),
          ),
        const Section('Kept on servers'),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text("Sessions pylond keeps for you appear when you connect to their host; resuming one takes a fresh login, so a stolen phone can't do it alone.", style: TextStyle(color: P.muted, fontSize: 13, height: 1.5)),
        ),
      ]),
    );
  }
}
