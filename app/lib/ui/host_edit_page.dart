import 'dart:io';

import 'package:flutter/material.dart';

import '../backend/model.dart';
import '../theme.dart';
import 'app_state.dart';
import 'widgets.dart';

class HostEditPage extends StatefulWidget {
  const HostEditPage({super.key, required this.st, this.host});
  final AppState st;
  final Host? host;

  @override
  State<HostEditPage> createState() => _HostEditPageState();
}

class _HostEditPageState extends State<HostEditPage> {
  late final name = TextEditingController(text: widget.host?.name ?? '');
  late final user = TextEditingController(text: widget.host?.user ?? '');
  late final addr = TextEditingController(text: widget.host?.address ?? '');
  late final port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final jump = TextEditingController(text: widget.host?.jump ?? '');
  late Mode mode = widget.host?.mode ?? Mode.ssh;
  String err = '';

  Future<void> _save() async {
    final p = int.tryParse(port.text.trim()) ?? 0;
    final typed = addr.text.trim();
    // An IPv6 address is kept without brackets.
    final a = typed.startsWith('[') && typed.endsWith(']') ? typed.substring(1, typed.length - 1) : typed;
    if (name.text.trim().isEmpty || user.text.trim().isEmpty || a.isEmpty || p < 1 || p > 65535) {
      setState(() => err = 'Give a name, a user, an address and a port from 1 to 65535.');
      return;
    }
    // Pylon mode follows the SSH connection to the address it reached, so a
    // name or an IPv4 or IPv6 address will do; through a jump host it must
    // be an address, reached directly.
    if (mode == Mode.pylon && jump.text.trim().isNotEmpty && InternetAddress.tryParse(a) == null) {
      setState(() => err = "Through a jump host, the Pylon protocol (v1) needs the host's address as an IP address (IPv4 or IPv6).");
      return;
    }
    final h = widget.host ?? Host(name: '', user: '', address: '');
    h
      ..name = name.text.trim()
      ..user = user.text.trim()
      ..address = a
      ..port = p
      ..jump = jump.text.trim()
      ..mode = mode;
    if (widget.host == null) widget.st.hosts.add(h);
    await widget.st.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final pin = widget.host == null ? null : widget.st.pinFor(widget.host!);
    return Scaffold(
      appBar: AppBar(title: Text(widget.host == null ? 'Add host' : widget.host!.name)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: user, decoration: const InputDecoration(labelText: 'User'))),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: TextField(controller: addr, decoration: const InputDecoration(labelText: 'Address'))),
          const SizedBox(width: 10),
          SizedBox(width: 84, child: TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port'))),
        ]),
        const SizedBox(height: 12),
        TextField(controller: jump, decoration: const InputDecoration(labelText: 'Reach through (optional)', hintText: 'user@jump-host[:port]')),
        const Section('Protocol'),
        SegmentedButton<Mode>(
          segments: const [ButtonSegment(value: Mode.ssh, label: Text('SSH')), ButtonSegment(value: Mode.pylon, label: Text('Pylon (roaming)'))],
          selected: {mode},
          onSelectionChanged: (v) => setState(() => mode = v.first),
        ),
        const SizedBox(height: 8),
        Text(mode == Mode.pylon ? "Pylon copies its small server into your account over SSH, checks it by hash, then keeps your sessions through network changes and sleep." : 'Plain SSH, with every protection of the profile.',
            style: const TextStyle(fontSize: 12, color: P.muted)),
        if (pin != null) ...[
          const Section('Host key'),
          Card2(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${pin.alg} ${pin.fingerprint}', style: const TextStyle(fontFamily: mono, fontSize: 12)),
            const SizedBox(height: 4),
            Text('Pinned ${pin.when} from ${pin.by}', style: const TextStyle(fontSize: 12, color: P.muted)),
          ])),
        ],
        if (err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err, style: const TextStyle(color: P.red))),
        const SizedBox(height: 24),
        FilledButton(onPressed: _save, child: const Text('Save')),
        if (widget.host != null)
          TextButton(
            onPressed: () async {
              widget.st.hosts.remove(widget.host);
              await widget.st.save();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Remove host', style: TextStyle(color: P.red)),
          ),
      ]),
    );
  }
}
