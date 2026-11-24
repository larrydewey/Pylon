import 'package:material_ui/material_ui.dart';

import '../backend/hostkey_qr.dart';
import '../backend/model.dart';
import '../backend/select.dart';
import '../theme.dart';
import 'access_help.dart';
import 'app_state.dart';
import 'scan_page.dart';
import 'widgets.dart';

/// Pin a host's key from a fingerprint obtained out of band (SPEC 6.1):
/// the core connects, verifies the key exchange, and pins only when the
/// key matches. There is no trust on first use, and none from a scanned
/// or pasted value by itself.
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

  static bool _hostKeyValue(String text) {
    try {
      parseHostKeyValue(text);
      return true;
    } on HostKeyValueError {
      return false;
    }
  }

  Future<void> _scan() async {
    final text = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const ScanPage(
          accepts: _hostKeyValue,
          title: 'Scan a shared pin',
          hint: "Point the camera at the code from Share pin on another device, or from pylon share on a computer.",
          wrong: 'That code holds no host key fingerprint.',
        ),
      ),
    );
    if (text == null || !mounted) return;
    setState(() {
      fp.text = text.trim();
      msg = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    const head = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFC9D1DB));
    return Scaffold(
      appBar: AppBar(title: Text('Pin ${h.name}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
        const Text("Pylon never trusts a host key the first time it sees it. Confirm it from somewhere the network can't touch, one of two ways:",
            style: TextStyle(fontSize: 15, height: 1.5, color: Color(0xFFC9D1DB))),
        const SizedBox(height: 14),
        Card2(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('From a device where this host is already pinned', style: head),
            const Para('In Pylon there: the host\'s settings (…) › Share pin, then scan its code here or paste its text. On a computer, this prints the text and a QR code:', top: 4),
            const SizedBox(height: 6),
            CopyLine('pylon share ${h.port != 22 ? '-p ${h.port} ' : ''}${h.address}'),
          ]),
        ),
        const SizedBox(height: 10),
        Card2(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            Text("From the server's console (its screen, or the provider's web console)", style: head),
            Para('Run this there and enter the SHA256:… fingerprint it prints:', top: 4),
            SizedBox(height: 6),
            CopyLine('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'),
          ]),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pin-value'),
          controller: fp,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Fingerprint or shared pin', hintText: 'SHA256:…  or  pylon-hostkey/1 …'),
          style: const TextStyle(fontFamily: mono, fontSize: 14),
        ),
        if (canScan) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(key: const Key('pin-scan'), icon: const Icon(Icons.qr_code_scanner, size: 18), label: const Text('Scan QR code'), onPressed: busy ? null : _scan),
        ],
        const SizedBox(height: 12),
        const Text('Pylon then connects and pins the key only if the host presents a matching one; what you scan or paste trusts nothing by itself. '
            'Hosts with a certificate from a CA you trust (Settings › Trusted host CAs) need no pin.',
            style: TextStyle(fontSize: 12, height: 1.4, color: P.muted)),
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
