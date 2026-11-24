import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../backend/access.dart';
import '../backend/model.dart';
import '../theme.dart';
import 'access_help.dart';
import 'app_state.dart';
import 'widgets.dart';

/// Adds public keys (or a CA) to a host's ~/.ssh/authorized_keys with
/// `pylon authorize`: Pylon logs in with this device's keys to do it, so
/// it works from a device that can already log in. Keys already there
/// are left as they are; nothing is removed.
class AuthorizePage extends StatefulWidget {
  const AuthorizePage({super.key, required this.st, required this.host});
  final AppState st;
  final Host host;

  @override
  State<AuthorizePage> createState() => _AuthorizePageState();
}

class _AuthorizePageState extends State<AuthorizePage> {
  final text = TextEditingController();

  /// This device's own keys (whatever the agent offers) instead of pasted
  /// lines.
  bool own = false;
  bool ca = false;
  Authorize? run;
  StreamSubscription<void>? sub;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    sub?.cancel();
    if (run?.ok == null) run?.close();
    text.dispose();
    super.dispose();
  }

  void _start(List<String> keys) {
    sub?.cancel();
    final a = widget.st.authorize(widget.host, own ? const [] : keys, ca: !own && ca);
    sub = a.changes.listen((_) {
      if (mounted) setState(() {});
    });
    setState(() => run = a);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    final parsed = parseKeyLines(text.text);
    final running = run != null && run!.ok == null;
    final ready = !running && (own || (parsed.keys.isNotEmpty && parsed.problems.isEmpty));
    return Scaffold(
      appBar: AppBar(title: const Text('Authorize a key')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Para(
            'Adds public keys to ~/.ssh/authorized_keys of ${h.user} on ${h.name}. Pylon logs in with this device\'s keys to do it, so use it from a device that can already log in. '
            'Keys already there stay as they are; nothing is removed.',
            top: 0),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('Paste keys')), ButtonSegment(value: true, label: Text("This device's keys"))],
          selected: {own},
          onSelectionChanged: running ? null : (v) => setState(() => own = v.first),
        ),
        const SizedBox(height: 12),
        if (own)
          const Para('Adds every key this device\'s agent offers (Symbolon\'s, on a phone), so that each of them is let in from now on, not only the one that logs in now.', top: 0)
        else ...[
          TextField(
            key: const Key('authorize-keys'),
            controller: text,
            enabled: !running,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: mono, fontSize: 12),
            decoration: const InputDecoration(labelText: 'Public key lines, one per line', hintText: 'ssh-ed25519 AAAA… name', alignLabelWithHint: true),
          ),
          const SizedBox(height: 6),
          if (parsed.problems.isNotEmpty)
            for (final p in parsed.problems) Text(p, style: const TextStyle(fontSize: 12, color: P.red))
          else
            Text(
              parsed.keys.isEmpty ? 'As a server\'s refusal or Symbolon shows it: TYPE, then the key, then a one-word name.' : '${parsed.keys.length} ${ca ? 'CA key' : 'key'}${parsed.keys.length == 1 ? '' : 's'} to add.',
              style: const TextStyle(fontSize: 12, color: P.muted),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('authorize-ca'),
            contentPadding: EdgeInsets.zero,
            value: ca,
            onChanged: running ? null : (v) => setState(() => ca = v),
            title: const Text('This is a certificate authority'),
            subtitle: Text('The server then accepts any certificate this CA signs for the user name ${h.user}, not just one key. Symbolon can be such a CA.',
                style: const TextStyle(fontSize: 12, color: P.muted)),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('authorize-run'),
          onPressed: ready ? () => _start(parsed.keys) : null,
          child: Text(running ? 'Logging in to ${h.name}…' : 'Authorize'),
        ),
        if (run != null) ..._result(run!),
      ]),
    );
  }

  List<Widget> _result(Authorize a) {
    final refusal = a.ok == false ? parseKeyRefusal(a.messages) : null;
    return [
      if (a.ok == null) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(color: P.teal, backgroundColor: P.line),
        const Para('Symbolon may ask you to approve the login.'),
      ],
      if (a.agentNote.isNotEmpty) Para(a.agentNote),
      if (a.lines.isNotEmpty) ...[
        const Section('What it did'),
        Card2(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final l in a.lines) _line(l)])),
      ],
      if (refusal != null)
        KeyRefusalCard(refusal: refusal, host: widget.host, st: widget.st, margin: const EdgeInsets.only(top: 16))
      else if (a.ok == false) ...[
        const SizedBox(height: 16),
        Card2(border: P.redLine, color: P.redDeep, child: Text(visible(a.messages.trim()), key: const Key('authorize-error'), style: const TextStyle(fontSize: 13))),
      ],
    ];
  }

  Widget _line(ReportLine l) {
    final (IconData icon, Color color, String label) = switch (l.kind) {
      ReportKind.added => (Icons.check_circle_outline, P.teal, 'Added'),
      ReportKind.present => (Icons.check, P.muted, 'Already there'),
      ReportKind.fixed => (Icons.build_outlined, P.amber, 'Fixed'),
      ReportKind.warning => (Icons.warning_amber, P.amber, 'Warning'),
      ReportKind.done => (Icons.done_all, P.teal, 'Done'),
      ReportKind.other => (Icons.notes, P.muted, ''),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(TextSpan(children: [
            if (label.isNotEmpty) TextSpan(text: label, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
            if (label.isNotEmpty && l.text.isNotEmpty) const TextSpan(text: '  '),
            TextSpan(
              text: visible(l.text, oneLine: true),
              style: TextStyle(fontFamily: l.kind == ReportKind.added || l.kind == ReportKind.present ? mono : null, fontSize: 12, color: P.text),
            ),
          ])),
        ),
      ]),
    );
  }
}
