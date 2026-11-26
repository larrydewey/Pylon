import 'package:material_ui/material_ui.dart';

import '../backend/model.dart';
import '../backend/select.dart';
import '../theme.dart';
import 'app_state.dart';
import 'prompts.dart';
import 'terminal_page.dart';
import 'widgets.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key, required this.st});
  final AppState st;

  void _show(BuildContext context, Host h) {
    final inTab = st.openInTab;
    if (inTab != null) {
      inTab(h);
      Navigator.popUntil(context, (r) => r.isFirst);
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => TerminalPage(st: st, host: h)));
    }
  }

  Future<void> _disconnect(BuildContext context, Session s) async {
    if (await confirmDisconnect(context, s)) st.end(s);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: st, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final live = st.live.where((s) => !s.local).toList();
    final ended = st.ended.where((s) => !s.local).toList();
    final local = st.sessionFor(Host.local());
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 16, 12, 24), children: [
        const Padding(padding: EdgeInsets.only(left: 8), child: Text('Sessions', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
        Section('On $deviceName'),
        if (live.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No live sessions.', style: TextStyle(color: P.muted))),
        for (final s in live)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card2(
              border: P.tealLine,
              onTap: st.openInTab != null ? null : () => _show(context, s.host),
              child: Row(children: [
                // The host's name as the principal gave it; the title the
                // host set, if any, under it and subordinate.
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.host.name, key: Key('session-host-${s.host.name}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    if (s.title.isNotEmpty) RemoteTitle(s.title, key: Key('session-title-${s.host.name}')),
                  ]),
                ),
                s.linkState == linkReconnecting
                    ? const Chip2('Reconnecting…', fg: P.amber, bg: Color(0xFF3A2C10))
                    : Chip2(s.host.mode == Mode.pylon ? 'Pylon · live' : 'SSH · live'),
                IconButton(
                  key: Key('disconnect-${s.host.name}'),
                  tooltip: 'Disconnect',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.link_off, color: P.muted, size: 20),
                  onPressed: () => _disconnect(context, s),
                ),
              ]),
            ),
          ),
        if (ended.isNotEmpty) ...[
          Row(children: [
            const Expanded(child: Section('Ended')),
            TextButton(key: const Key('clear-ended'), onPressed: st.clearEnded, child: const Text('Clear all')),
          ]),
          for (final s in ended)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card2(
                border: P.redLine,
                // Tapping it connects again, in place of the ended one.
                onTap: st.openInTab != null
                    ? null
                    : () {
                        st.reconnect(s);
                        _show(context, s.host);
                      },
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.host.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        s.status.trim().isNotEmpty ? visible(s.status.trim().split('\n').last) : 'Ended (${s.exitCode})',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: P.muted),
                      ),
                    ]),
                  ),
                  IconButton(
                    key: Key('remove-${s.host.name}'),
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, color: P.muted, size: 20),
                    onPressed: () => st.end(s),
                  ),
                ]),
              ),
            ),
        ],
        const Section('Kept on servers'),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text("Sessions pylond keeps for you appear when you connect to their host; resuming one takes a fresh login, so a stolen phone can't do it alone.", style: TextStyle(color: P.muted, fontSize: 13, height: 1.5)),
        ),
        if (st.backend.hasLocalShell) ...[
          Section('On $deviceName only'),
          Card2(
            color: P.purpleDeep,
            border: P.purpleLine,
            onTap: () => _show(context, Host.local()),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Local shell', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: P.localText))),
                Text(local != null ? 'Live' : (deviceName == 'this phone' ? 'This phone' : 'This computer'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: P.purple)),
                if (local != null)
                  IconButton(
                    key: const Key('end-local'),
                    tooltip: 'End the local shell',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, color: P.localMuted, size: 20),
                    onPressed: () => _disconnect(context, local),
                  ),
              ]),
              const SizedBox(height: 6),
              const Text('Separate sandbox, no access to your keys', style: TextStyle(fontSize: 13, color: P.localMuted)),
            ]),
          ),
        ],
      ]),
    );
  }
}
