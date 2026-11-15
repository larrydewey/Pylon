import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_state.dart';
import 'warning_page.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.st});
  final AppState st;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 16, 12, 24), children: [
        const Padding(padding: EdgeInsets.only(left: 8), child: Text('Settings', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
        const Section('Keys and trust'),
        Card2(
          padding: EdgeInsets.zero,
          child: Column(children: [
            ListTile(
              title: const Text('Key custodian'),
              trailing: const Text('Symbolon', style: TextStyle(color: P.tealText)),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WarningPage())),
            ),
            const Divider(height: 1),
            ListTile(title: const Text('Trusted host CAs'), trailing: const Icon(Icons.chevron_right, color: P.muted), onTap: () => _addCa(context)),
            const Divider(height: 1),
            ListTile(title: const Text('Pinned hosts'), trailing: Text('${st.pinList.length}', style: const TextStyle(color: P.muted))),
          ]),
        ),
        const Section('Terminal'),
        Card2(
          padding: EdgeInsets.zero,
          child: Column(children: [
            SwitchListTile(
              title: const Text('Hide keystroke timing'),
              subtitle: const Text('Recommended; adds up to 20 ms', style: TextStyle(color: P.muted)),
              value: st.obfuscateKeys,
              onChanged: (v) => setState(() => st.obfuscateKeys = v),
            ),
            const Divider(height: 1),
            SwitchListTile(
              title: const Text('Block screenshots'),
              subtitle: const Text('Also hides the terminal in recent apps', style: TextStyle(color: P.muted)),
              value: st.blockScreenshots,
              onChanged: (v) => setState(() => st.blockScreenshots = v),
            ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _addCa(BuildContext context) async {
    final pat = TextEditingController(), key = TextEditingController();
    String msg = '';
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          backgroundColor: P.surface,
          title: const Text('Trust a host CA'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Hosts whose certificate this CA signed, for names under the pattern, need no pin. Get the CA key out of band.', style: TextStyle(fontSize: 13, color: P.muted)),
            const SizedBox(height: 12),
            TextField(controller: pat, decoration: const InputDecoration(labelText: 'Pattern', hintText: '*.example.org')),
            const SizedBox(height: 8),
            TextField(controller: key, decoration: const InputDecoration(labelText: 'CA public key', hintText: 'ssh-ed25519 AAAA…'), style: const TextStyle(fontFamily: mono, fontSize: 12)),
            if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(visible(msg), style: const TextStyle(fontSize: 12))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
              onPressed: () async {
                final r = await widget.st.backend.trustCa(pat.text.trim(), key.text.trim());
                set(() => msg = r.message);
              },
              child: const Text('Trust'),
            ),
          ],
        ),
      ),
    );
  }
}
