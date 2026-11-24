import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../backend/access.dart';
import '../backend/model.dart';
import '../theme.dart';
import 'app_state.dart';
import 'authorize_page.dart';
import 'pin_page.dart';
import 'widgets.dart';

/// Copies text that is not secret (a public key, a command, a pin) and
/// says so.
Future<void> copyPlain(BuildContext context, String text, {String what = 'Copied'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(what), duration: const Duration(seconds: 2)));
  }
}

/// A line to copy as it is (a key, a command), in monospace, with a Copy
/// button.
class CopyLine extends StatelessWidget {
  const CopyLine(this.text, {super.key, this.what = 'Copied', this.label = 'Copy'});
  final String text, what, label;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
        decoration: BoxDecoration(color: P.ink2, borderRadius: BorderRadius.circular(8), border: Border.all(color: P.line)),
        child: Row(children: [
          // Shown with any control characters made visible; copied as it is.
          Expanded(child: SelectableText(visible(text, oneLine: true), style: const TextStyle(fontFamily: mono, fontSize: 12, height: 1.4))),
          IconButton(tooltip: label, icon: const Icon(Icons.content_copy, size: 18, color: P.muted), onPressed: () => copyPlain(context, text, what: what)),
        ]),
      );
}

/// Muted body text for the explanations.
class Para extends StatelessWidget {
  const Para(this.text, {super.key, this.top = 8});
  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: top),
        child: Text(text, style: const TextStyle(fontSize: 13, height: 1.45, color: Color(0xFFC9D1DB))),
      );
}

/// The host refused every key this device offered: what that means, the
/// keys to add, the command that adds them from a device that can log
/// in, and the way to do it by hand. The core's own text stays a tap away.
class KeyRefusalCard extends StatefulWidget {
  const KeyRefusalCard({super.key, required this.refusal, required this.host, this.st, this.margin = const EdgeInsets.fromLTRB(12, 8, 12, 0)});
  final KeyRefusal refusal;
  final Host host;

  /// For the way to "Getting access to a server"; none, no link.
  final AppState? st;
  final EdgeInsets margin;

  @override
  State<KeyRefusalCard> createState() => _KeyRefusalCardState();
}

class _KeyRefusalCardState extends State<KeyRefusalCard> {
  bool raw = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.refusal;
    final h = widget.host;
    // The refusing host may be the jump host: the core names it.
    final target = r.target.isNotEmpty ? r.target : h.target;
    final user = target.contains('@') ? target.substring(0, target.lastIndexOf('@')) : h.user;
    final commands = r.commands.isNotEmpty ? r.commands : [if (r.keys.isNotEmpty && target == h.target) authorizeCommand(target, h.port, h.jump, r.keys)];
    const label = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: P.text);
    return Container(
      key: const Key('key-refusal'),
      width: double.infinity,
      margin: widget.margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: P.amberDeep, borderRadius: BorderRadius.circular(12), border: Border.all(color: P.amberLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${visible(target, oneLine: true)} refused this device\'s key', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: P.amber)),
        Para('The server lets in only keys listed in ~/.ssh/authorized_keys of ${visible(user, oneLine: true)} there, and this device\'s key is not in it. '
            'It has to be added on the server once. Every device in your Symbolon quorum uses this same key, so once it is added, all of them can log in.'),
        if (r.keys.isEmpty && r.certificates == 0)
          const Para('No key was offered: the agent has none. In Symbolon, open SSH keys and make one (or import one); its public key line is what the server needs.', top: 6),
        for (final n in r.notes) Para(visible(n), top: 6),
        if (r.keys.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(r.keys.length == 1 ? 'The key to add' : 'The keys offered (add one)', style: label),
          for (final k in r.keys) Padding(padding: const EdgeInsets.only(top: 6), child: CopyLine(k, what: 'Key copied')),
        ],
        if (r.certificates > 0)
          Para('${r.certificates == 1 ? 'A certificate was' : '${r.certificates} certificates were'} offered too; that is not a key to copy. '
              'The server accepts a certificate only if it trusts the CA that signed it.', top: 6),
        if (commands.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('From a device that can already log in', style: label),
          Para('In Pylon there: the host\'s settings (…) › Authorize a key, and paste the key. On a computer, run:', top: 4),
          for (final c in commands) Padding(padding: const EdgeInsets.only(top: 6), child: CopyLine(c, what: 'Command copied')),
        ],
        const SizedBox(height: 12),
        const Text('Or by hand, on the server', style: label),
        const Para('Append the key line to ~/.ssh/authorized_keys, then run:', top: 4),
        const SizedBox(height: 6),
        CopyLine(r.fix ?? modesFix, what: 'Command copied'),
        const SizedBox(height: 8),
        Wrap(spacing: 4, children: [
          TextButton(
            key: const Key('key-refusal-raw'),
            onPressed: () => setState(() => raw = !raw),
            child: Text(raw ? 'Hide the full message' : 'Show the full message'),
          ),
          if (widget.st != null)
            TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccessPage(st: widget.st!, host: h.local ? null : h))),
              child: const Text('How access works'),
            ),
        ]),
        if (raw) SelectableText(visible(r.raw), key: const Key('key-refusal-text'), style: const TextStyle(fontFamily: mono, fontSize: 11, color: P.muted)),
      ]),
    );
  }
}

/// "Getting access to a server": pin its key, then let your key in, in
/// plain steps. For [host], what is done already and the way to do the
/// rest.
class AccessPage extends StatefulWidget {
  const AccessPage({super.key, required this.st, this.host});
  final AppState st;
  final Host? host;

  @override
  State<AccessPage> createState() => _AccessPageState();
}

class _AccessPageState extends State<AccessPage> {
  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    final pinned = h != null && widget.st.pinFor(h) != null;
    final name = h == null ? 'HOST' : h.address;
    final user = h == null ? 'USER' : h.user;
    final port = h == null || h.port == 22 ? '' : '-p ${h.port} ';
    return Scaffold(
      appBar: AppBar(title: const Text('Getting access to a server')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Para(
            'Two things, once per server. Pylon checks that the server is the one you mean (its host key), and the server checks that you are someone it lets in (your key).',
            top: 0),
        const Section('1 · Pin the server\'s host key'),
        Card2(
          border: pinned ? P.tealLine : P.line,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (h != null) _state(pinned, pinned ? 'Pinned' : 'Not pinned yet'),
            const Para(
                'Pylon connects only to a server whose key you confirmed from somewhere the network can\'t touch, so nobody in between can pretend to be it. Get it one of two ways:',
                top: 0),
            const Para('From a device where it is already pinned: in Pylon there, open the host\'s settings (…) › Share pin, and scan the code on this device (or paste its text). On a computer, this prints the same text and a QR code:'),
            const SizedBox(height: 6),
            CopyLine('pylon share $port$name'),
            const Para('From the server\'s own console (its screen, or the provider\'s web console): run this and enter the SHA256:… fingerprint it prints:'),
            const SizedBox(height: 6),
            const CopyLine('ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'),
            const Para('Either way, Pylon then connects and pins the key only if the server presents a matching one. A code or text by itself trusts nothing.'),
            if (h != null && !pinned) ...[
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('access-pin'),
                onPressed: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => PinPage(st: widget.st, host: h)));
                  if (mounted) setState(() {});
                },
                child: const Text('Pin the host key'),
              ),
            ],
          ]),
        ),
        const Section('2 · Let your key in'),
        Card2(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Para(
                'The server lets you in only with a key listed in ~/.ssh/authorized_keys of $user there. Your key is in Symbolon (on a computer, in your SSH agent). '
                'Every device in your Symbolon quorum signs with the same key, so adding it once lets all of them in.',
                top: 0),
            const Para('From a device that can already log in: in Pylon there, open the host\'s settings (…) › Authorize a key, and paste the key line. On a computer:'),
            const SizedBox(height: 6),
            CopyLine("pylon authorize $port$user@$name 'ssh-ed25519 AAAA… name'"),
            const Para('Or by hand on the server: append the key line to ~/.ssh/authorized_keys, then run'),
            const SizedBox(height: 6),
            const CopyLine(modesFix),
            const Para('Your key line is in Symbolon, under SSH keys. Pylon also shows it, with a Copy button, whenever a server refuses it. '
                'If no device can log in yet, use the server\'s console, or the provider\'s setup (most ask for a public key when the server is created).'),
          ]),
        ),
        const Section('Or: trust a certificate authority'),
        const Card2(
          child: Para(
              'Instead of adding each key, the server can accept any certificate that a CA signs for your user name. Add the CA\'s public key once, with Authorize a key › This is a certificate authority. '
              'Symbolon can be such a CA; keys it certifies later need no change on the server.',
              top: 0),
        ),
        if (h != null && !h.local) ...[
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const Key('access-authorize'),
            icon: const Icon(Icons.key_outlined, size: 18),
            label: const Text('Authorize a key on this host'),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AuthorizePage(st: widget.st, host: h))),
          ),
        ],
      ]),
    );
  }

  Widget _state(bool done, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Chip2(text, fg: done ? P.tealText : P.amber, bg: done ? P.tealDeep : const Color(0xFF3A2C10)),
      );
}
