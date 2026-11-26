import 'package:material_ui/material_ui.dart';

import '../backend/access.dart';
import '../backend/model.dart';
import '../theme.dart';
import 'access_help.dart';
import 'app_state.dart';
import 'widgets.dart';

/// The core's messages for a session, above its terminal: the pylond
/// release it checked, the Pylon protocol session it opened, the host's
/// banner. While the session is live they fold to their first line (tap
/// for the rest), so the terminal keeps the room; while it starts, and
/// once it has ended (the reason, usually), they are shown whole. When
/// the host refused every key, what to do about it instead (the message
/// itself a tap away).
class SessionNote extends StatefulWidget {
  const SessionNote({super.key, required this.session, this.padding = 12, this.st});
  final Session session;
  final double padding;

  /// For the refusal card's way to "Getting access to a server".
  final AppState? st;

  @override
  State<SessionNote> createState() => _SessionNoteState();
}

class _SessionNoteState extends State<SessionNote> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final text = visible(s.status.trim());
    if (text.isEmpty) return const SizedBox.shrink();
    final refusal = s.local ? null : parseKeyRefusal(s.status);
    if (refusal != null) {
      // Above the terminal, which keeps some room: the card scrolls.
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: SingleChildScrollView(child: KeyRefusalCard(refusal: refusal, host: s.host, st: widget.st)),
      );
    }
    final ended = s.exitCode != null;
    final starting = text.startsWith('Connecting') || text.startsWith('Starting');
    final lines = text.split('\n');
    final foldable = !ended && !starting && lines.length > 1;
    final folded = foldable && !open;
    final box = Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: EdgeInsets.symmetric(horizontal: widget.padding, vertical: folded ? 8 : widget.padding),
      decoration: BoxDecoration(color: ended ? P.redDeep : P.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: ended ? P.redLine : P.line)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(
            folded ? lines.first : text,
            key: const Key('session-note'),
            maxLines: folded ? 1 : null,
            overflow: folded ? TextOverflow.ellipsis : null,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE6CFCF)),
          ),
        ),
        if (foldable) ...[
          if (folded)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('+${lines.length - 1}', style: const TextStyle(fontSize: 12, color: P.muted)),
            ),
          Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: P.muted),
        ],
      ]),
    );
    if (!foldable) return box;
    return Semantics(
      button: true,
      label: open ? 'Hide connection details' : 'Show connection details',
      child: GestureDetector(key: const Key('session-note-toggle'), behavior: HitTestBehavior.opaque, onTap: () => setState(() => open = !open), child: box),
    );
  }
}

/// The Pylon protocol's link above the terminal (SPEC 9.8), so nobody has
/// to guess what a quiet terminal is doing: while the host does not
/// answer, amber, with how long and that the core keeps trying; back, a
/// few seconds of "Reconnected"; and once a session to a host has ended,
/// a way to connect again: to the same shell when only the link was lost
/// (the host keeps it), else to a new one.
class LinkNote extends StatelessWidget {
  const LinkNote({super.key, required this.session, required this.onReconnect, this.padding = 12});
  final Session session;
  final VoidCallback onReconnect;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s.local) return const SizedBox.shrink();
    if (s.exitCode != null) {
      final kept = s.resumable;
      return _card(
        color: kept ? P.amberDeep : P.surface,
        border: kept ? P.amberLine : P.line,
        icon: kept ? Icons.pause_circle_outline : Icons.restart_alt,
        fg: kept ? P.amber : P.muted,
        text: kept
            ? 'Your shell is still running on ${visible(s.host.name, oneLine: true)} (session ${s.keptSession}). Reconnecting signs in again and picks it up where you left it.'
            : 'Connecting again starts a new shell.',
        action: FilledButton(key: const Key('reconnect'), onPressed: onReconnect, child: Text(kept ? 'Reconnect' : 'Connect again')),
      );
    }
    if (s.linkNote.isEmpty) return const SizedBox.shrink();
    final quiet = s.linkState == linkReconnecting;
    return Semantics(
      liveRegion: true,
      child: _card(
        key: const Key('link-note'),
        color: quiet ? P.amberDeep : P.tealDeep,
        border: quiet ? P.amberLine : P.tealLine,
        icon: quiet ? Icons.sync_problem : Icons.check_circle_outline,
        fg: quiet ? P.amber : P.tealText,
        text: quiet
            ? '${visible(s.linkNote)}\nYour shell keeps running on the host; what you type goes through once it answers.'
            : visible(s.linkNote),
      ),
    );
  }

  Widget _card({Key? key, required Color color, required Color border, required IconData icon, required Color fg, required String text, Widget? action}) => Container(
        key: key,
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12), border: Border.all(color: border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4, color: P.text))),
          ]),
          if (action != null) ...[const SizedBox(height: 10), action],
        ]),
      );
}
