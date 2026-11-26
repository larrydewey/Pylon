import 'package:material_ui/material_ui.dart';

import '../backend/model.dart';
import '../theme.dart';
import 'app_state.dart';
import 'files_page.dart';
import 'host_edit_page.dart';
import 'pin_page.dart';
import 'terminal_page.dart';
import 'widgets.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({super.key, required this.st});
  final AppState st;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final hosts = st.hosts.where((h) => q.isEmpty || h.name.contains(q) || h.address.contains(q)).toList();
    final attached = hosts.where((h) => st.sessionFor(h) != null).toList();
    final rest = hosts.where((h) => st.sessionFor(h) == null).toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: P.teal,
        foregroundColor: P.ink,
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => HostEditPage(st: st)));
          setState(() {});
        },
        label: const Text('Add host', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 16, 12, 96), children: [
          Row(children: [
            const SizedBox(width: 8),
            const PylonMark(size: 28),
            const SizedBox(width: 10),
            const Text('Hosts', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (st.backend.demo) const Chip2('Demo', fg: P.amber, bg: Color(0xFF3A2C10)),
          ]),
          const SizedBox(height: 14),
          TextField(decoration: const InputDecoration(hintText: 'Search hosts'), onChanged: (v) => setState(() => q = v)),
          if (attached.isNotEmpty) const Section('Attached'),
          for (final h in attached) _hostCard(context, h),
          if (rest.isNotEmpty) const Section('Hosts'),
          for (final h in rest) _hostCard(context, h),
          if (hosts.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('No hosts yet. Add one, then pin its key.', style: TextStyle(color: P.muted))),
        ]),
      ),
    );
  }

  Widget _hostCard(BuildContext context, Host h) {
    final st = widget.st;
    final pin = st.pinFor(h);
    final live = st.sessionFor(h) != null;
    final pinned = pin != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card2(
        border: live ? P.tealLine : (pinned ? P.line : P.amberLine),
        color: pinned || live ? P.surface : P.amberDeep,
        onTap: () async {
          if (!pinned) {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => PinPage(st: st, host: h)));
          } else if (st.openInTab != null) {
            // The desktop layout: a tab of its own, back in the workspace.
            st.openInTab!(h);
            Navigator.popUntil(context, (r) => r.isFirst);
            return;
          } else {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => TerminalPage(st: st, host: h)));
          }
          setState(() {});
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(h.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
            if (live && st.sessionFor(h)!.linkState == linkReconnecting)
              const Chip2('Reconnecting…', fg: P.amber, bg: Color(0xFF3A2C10))
            else if (live)
              Chip2(h.mode == Mode.pylon ? 'Pylon · roaming' : 'SSH · live')
            else if (!pinned)
              const Chip2('Not pinned', fg: P.amber, bg: Color(0xFF3A2C10))
            else
              Chip2(h.jump.isNotEmpty ? 'via ${h.jump.split('@').last}' : (h.mode == Mode.pylon ? 'Pylon' : 'SSH'), fg: const Color(0xFFC9D1DB), bg: const Color(0xFF222934)),
          ]),
          const SizedBox(height: 6),
          Text(h.target, style: const TextStyle(fontFamily: mono, fontSize: 13, color: P.muted)),
          const SizedBox(height: 6),
          if (pinned)
            Text('${pin.alg.replaceAll('ssh-', '').replaceAll('ecdsa-sha2-nistp256', 'ecdsa')} ${pin.fingerprint}', style: const TextStyle(fontFamily: mono, fontSize: 12, color: P.muted))
          else
            const Text("Pylon won't connect until you pin this host's key from a source you trust.", style: TextStyle(fontSize: 13, color: Color(0xFFD9CBAE))),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (pinned)
              IconButton(
                tooltip: 'Files',
                icon: const Icon(Icons.folder_outlined, color: P.muted),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FilesPage(st: st, host: h))),
              ),
            IconButton(
              tooltip: 'Edit host',
              icon: const Icon(Icons.more_horiz, color: P.muted),
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => HostEditPage(st: st, host: h)));
                setState(() {});
              },
            ),
          ]),
        ]),
      ),
    );
  }
}
