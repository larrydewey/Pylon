import 'package:flutter/material.dart';

import '../backend/model.dart';
import '../theme.dart';
import 'app_state.dart';
import 'widgets.dart';

class SessionPage extends StatelessWidget {
  const SessionPage({super.key, required this.st, required this.host});
  final AppState st;
  final Host host;

  @override
  Widget build(BuildContext context) {
    final s = st.sessionFor(host);
    final pin = st.pinFor(host);
    final pylon = host.mode == Mode.pylon;
    return Scaffold(
      appBar: AppBar(title: Text(host.name)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card2(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            Row2('Protocol', pylon ? 'Pylon v1 over UDP' : 'SSH 2.0, strict key exchange'),
            Row2('Key exchange', pylon ? 'ML-KEM-768 + X25519' : 'ML-KEM-768 + X25519, or X25519'),
            Row2('Host key', pin == null ? 'certificate or pin' : '${pin.alg.replaceAll('ssh-', '')} · pinned', monoValue: true),
            const Row2('Signed by', 'your agent (Symbolon)'),
            Row2('Keystrokes', st.obfuscateKeys ? 'Timing hidden' : 'Sent as typed'),
          ]),
        ),
        if (pylon) ...[
          const Section('On the server'),
          const Card2(child: Text('pylond, verified by hash, confined (Landlock and seccomp). Kept until you end it, or after 7 days with no device attached; resuming from another device takes a fresh login.', style: TextStyle(fontSize: 13, color: Color(0xFFC9D1DB), height: 1.5))),
        ],
        const SizedBox(height: 24),
        if (s != null)
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: P.red, side: const BorderSide(color: P.redLine)),
            onPressed: () {
              st.end(s);
              Navigator.pop(context);
            },
            child: const Text('End session'),
          ),
      ]),
    );
  }
}
