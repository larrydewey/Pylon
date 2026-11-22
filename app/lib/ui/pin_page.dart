import 'package:material_ui/material_ui.dart';

import '../backend/model.dart';
import '../theme.dart';
import 'app_state.dart';
import 'widgets.dart';

/// Pin a host's key from a fingerprint obtained out of band (SPEC 6.1):
/// the core connects, verifies the key exchange, and pins only when the
/// key matches. There is no trust on first use.
class PinPage extends StatefulWidget {
  const PinPage({super.key, required this.st, required this.host});
  final AppState st;
  final Host host;

  @override
  State<PinPage> createState() => _PinPageState();
}

class _PinPageState extends State<PinPage> {
  final fp = TextEditingController();
  String msg = '';
  bool busy = false, ok = false;

  Future<void> _pin() async {
    setState(() => busy = true);
    final r = await widget.st.backend.pin(widget.host, fp.text.trim());
    await widget.st.refreshPins();
    setState(() {
      busy = false;
      ok = r.ok;
      msg = r.message;
    });
    if (r.ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    return Scaffold(
      appBar: AppBar(title: Text('Pin ${h.name}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
        const Text("Pylon never trusts a host key the first time it sees it. Get the fingerprint from somewhere the network can't touch: the provider's web console, the machine's screen, or a QR code.",
            style: TextStyle(fontSize: 15, height: 1.5, color: Color(0xFFC9D1DB))),
        const SizedBox(height: 18),
        TextField(controller: fp, decoration: const InputDecoration(labelText: 'Fingerprint', hintText: 'SHA256:…'), style: const TextStyle(fontFamily: mono, fontSize: 14)),
        const SizedBox(height: 16),
        Card2(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            Text("On the server's console, run", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFC9D1DB))),
            SizedBox(height: 6),
            SelectableText('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub', style: TextStyle(fontFamily: mono, fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 12),
        const Text('Hosts with a certificate from a CA you trust (Settings › Trusted host CAs) need no pin.', style: TextStyle(fontSize: 12, color: P.muted)),
        if (msg.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card2(border: ok ? P.tealLine : P.redLine, color: ok ? P.tealDeep : P.redDeep, child: Text(visible(msg), style: const TextStyle(fontSize: 13))),
        ],
        const SizedBox(height: 24),
        FilledButton(onPressed: busy ? null : _pin, child: Text(busy ? 'Checking the host…' : 'Pin and connect')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ]),
    );
  }
}
