import 'package:flutter/material.dart';

import '../theme.dart';

/// SPEC 7.6: the warning shown before a key is used without Symbolon,
/// acknowledged only by typing "I understand".
class WarningPage extends StatefulWidget {
  const WarningPage({super.key});

  @override
  State<WarningPage> createState() => _WarningPageState();
}

class _WarningPageState extends State<WarningPage> {
  final ack = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final ok = ack.text.trim() == 'I understand';
    return Scaffold(
      backgroundColor: const Color(0xFF15110A),
      appBar: AppBar(backgroundColor: const Color(0xFF15110A)),
      body: ListView(padding: const EdgeInsets.fromLTRB(22, 8, 22, 24), children: [
        const Text('You are about to use Pylon without Symbolon.', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.2)),
        const SizedBox(height: 14),
        const Text('Your SSH key will live in one place. If this device is lost, stolen or compromised, whoever holds it can log in to every server that trusts this key, and you cannot revoke it everywhere at once.',
            style: TextStyle(fontSize: 14, height: 1.55, color: Color(0xFFE3D7C3))),
        const SizedBox(height: 14),
        for (final l in const ['Confirming each login with you', 'Stopping a signature from being reused elsewhere', 'Trusted hosts kept in sync across your devices', 'Duress protection'])
          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('— $l', style: const TextStyle(fontSize: 14))),
        const SizedBox(height: 12),
        const Text("Hosts you pin here are pinned on this device only. Pylon's other protections still apply. Only the safety of your key changes.", style: TextStyle(fontSize: 13, height: 1.5, color: Color(0xFFC9BBA2))),
        const SizedBox(height: 20),
        TextField(controller: ack, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Type I understand to continue'), style: const TextStyle(fontFamily: mono)),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: ok ? () => Navigator.pop(context, true) : null, child: const Text('Use this key anyway', style: TextStyle(color: P.amber))),
        const SizedBox(height: 10),
        FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text('Set up Symbolon instead')),
      ]),
    );
  }
}
