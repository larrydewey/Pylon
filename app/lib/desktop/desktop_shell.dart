import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../backend/model.dart';
import '../backend/select.dart';
import '../term/term_view.dart';
import '../theme.dart';
import '../ui/app_state.dart';
import '../ui/home.dart';
import '../ui/pin_page.dart';
import '../ui/prompts.dart';
import '../ui/session_note.dart';
import '../ui/widgets.dart';
import 'layout.dart';

/// The Linux desktop (SPEC 15, phase 2): sessions as tabs, each tab split
/// into panes, a title bar of tabs, a status bar of what protects the
/// focused pane. Shortcuts take Ctrl+Shift, which shells leave alone:
///
///   Ctrl+Shift+T  new tab (choose a host or the local shell)
///   Ctrl+Shift+L  new local shell tab
///   Ctrl+Shift+E  split right: a new session to the focused pane's host
///   Ctrl+Shift+O  split down
///   Ctrl+Shift+W  close the focused pane (ends its session)
///   Ctrl+Shift+arrows   focus the pane on that side
///   Ctrl+PageUp/PageDown previous / next tab
///   Ctrl+Shift+V  paste      Ctrl+Shift+K  commands
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.st});
  final AppState st;

  @override
  State<DesktopShell> createState() => DesktopShellState();
}

/// What the command palette chose.
class Choice {
  const Choice(this.host, this.where, {this.manage = false});
  final Host? host;

  /// null: a new tab.
  final SplitDir? where;

  /// Hosts and settings.
  final bool manage;
}

class DesktopShellState extends State<DesktopShell> {
  late final Workspace ws = Workspace(widget.st.end);
  final Map<int, GlobalKey<TermViewState>> _views = {};
  final Map<Session, StreamSubscription<void>> _subs = {};
  int? _focusedId;

  @override
  void initState() {
    super.initState();
    ws.addListener(_changed);
    // Screens, titles and exits arrive through the sessions' AppState.
    widget.st.addListener(_redraw);
    HardwareKeyboard.instance.addHandler(_onKey);
    widget.st.openInTab = (h) => open(h);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    widget.st.openInTab = null;
    for (final s in _subs.values) {
      s.cancel();
    }
    ws.removeListener(_changed);
    widget.st.removeListener(_redraw);
    ws.closeAll();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    // Panes that went: their views and subscriptions with them.
    final live = {for (final t in ws.tabs) ...t.panes};
    _views.removeWhere((id, _) => !live.any((p) => p.id == id));
    for (final s in _subs.keys.where((s) => !live.any((p) => p.session == s)).toList()) {
      _subs.remove(s)?.cancel();
    }
    setState(() {});
    final f = ws.focused;
    if (f != null && f.id != _focusedId) {
      _focusedId = f.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) _views[f.id]?.currentState?.focus();
      });
    }
  }

  /// A new session to [h] in a new tab, or beside the focused pane.
  /// A host not pinned yet goes to pinning first (no trust on first use).
  Pane? open(Host h, {SplitDir? where, int? attach}) {
    if (!h.local && widget.st.pinFor(h) == null && !widget.st.backend.demo) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PinPage(st: widget.st, host: h)));
      return null;
    }
    final s = widget.st.openNew(h, 24, 80, attach: attach);
    _subs[s] = s.changes.listen((_) {
      if (mounted && s.clipboardRequests.isNotEmpty) askClipboard(context, s);
    });
    return where == null ? ws.openTab(s) : ws.split(where, s);
  }

  /// A split with a new session to the focused pane's host.
  void _splitSame(SplitDir d) {
    final f = ws.focused;
    if (f == null) {
      _palette();
      return;
    }
    open(f.session.local ? Host.local() : f.session.host, where: d);
  }

  /// The workspace's shortcuts, seen before the focus system; the
  /// focused terminal is told to leave the same keys alone ([reserved]),
  /// since the focus system sees them too.
  bool _onKey(KeyEvent e) {
    if (e is KeyUpEvent || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final a = _action(e);
    if (a == null || (e is KeyRepeatEvent && !_arrow(e.logicalKey))) return false;
    a();
    return true;
  }

  /// Whether [e] is one of the workspace's shortcuts.
  bool reserved(KeyEvent e) => _action(e) != null;

  VoidCallback? _action(KeyEvent e) {
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed, shift = hk.isShiftPressed, alt = hk.isAltPressed, meta = hk.isMetaPressed;
    if (!ctrl || alt || meta) return null;
    final k = e.logicalKey;
    if (!shift) {
      if (k == LogicalKeyboardKey.pageDown) return () => ws.cycle(1);
      if (k == LogicalKeyboardKey.pageUp) return () => ws.cycle(-1);
      return null;
    }
    final f = ws.focused;
    return switch (k) {
      LogicalKeyboardKey.keyT || LogicalKeyboardKey.keyK => _palette,
      LogicalKeyboardKey.keyL => () => open(Host.local()),
      LogicalKeyboardKey.keyE => () => _splitSame(SplitDir.right),
      LogicalKeyboardKey.keyO => () => _splitSame(SplitDir.down),
      LogicalKeyboardKey.keyW => () => f == null ? null : ws.closePane(f),
      LogicalKeyboardKey.keyV => () => f == null ? null : pasteInto(context, f.session),
      LogicalKeyboardKey.arrowLeft => () => ws.move(Dir.left),
      LogicalKeyboardKey.arrowRight => () => ws.move(Dir.right),
      LogicalKeyboardKey.arrowUp => () => ws.move(Dir.up),
      LogicalKeyboardKey.arrowDown => () => ws.move(Dir.down),
      _ => null,
    };
  }

  static bool _arrow(LogicalKeyboardKey k) => k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown;

  Future<void> _palette() async {
    final c = await showDialog<Choice>(context: context, builder: (_) => Palette(st: widget.st, canSplit: ws.tab != null));
    if (c == null || !mounted) return;
    if (c.manage) {
      _manage();
    } else if (c.host != null) {
      open(c.host!, where: c.where);
    }
  }

  void _manage() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: const Text('Hosts and settings')), body: Home(st: widget.st))),
      );

  GlobalKey<TermViewState> _viewKey(Pane p) => _views.putIfAbsent(p.id, () => GlobalKey<TermViewState>(debugLabel: 'pane ${p.id}'));

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: P.ink,
        body: Column(children: [
          _titleBar(),
          Expanded(child: ws.tabs.isEmpty ? _empty() : IndexedStack(index: ws.active, children: [for (final t in ws.tabs) _node(t, t.root)])),
          _statusBar(),
        ]),
      );

  Widget _titleBar() => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(color: P.surface, border: Border(bottom: BorderSide(color: P.line))),
        child: Row(children: [
          const Padding(padding: EdgeInsets.only(right: 8), child: PylonMark(size: 20)),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (var i = 0; i < ws.tabs.length; i++) Padding(padding: const EdgeInsets.only(right: 4), child: _tabButton(i)),
                IconButton(tooltip: 'New tab (Ctrl+Shift+T)', iconSize: 18, icon: const Icon(Icons.add, color: P.muted), onPressed: _palette),
              ]),
            ),
          ),
          Text('$agentNote · Ctrl+Shift+K commands', style: const TextStyle(fontSize: 12, color: P.muted)),
          IconButton(tooltip: 'Hosts and settings', iconSize: 18, icon: const Icon(Icons.settings_outlined, color: P.muted), onPressed: _manage),
        ]),
      );

  Widget _tabButton(int i) {
    final t = ws.tabs[i];
    final first = t.panes.first.session;
    final sel = i == ws.active;
    final n = t.panes.length;
    final prod = !first.local && first.host.tag == 'production';
    final ended = t.panes.every((p) => p.session.exitCode != null);
    final name = first.local ? 'local' : first.host.name;
    final color = first.local ? P.purple : (prod ? P.red : (sel ? P.text : P.muted));
    return Material(
      color: sel ? (first.local ? P.purpleDeep : P.tealDeep) : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: sel ? BorderSide(color: first.local ? P.purpleLine : P.tealLine) : BorderSide.none),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => ws.select(i),
        child: Container(
          height: 32,
          padding: const EdgeInsets.only(left: 14, right: 6),
          child: Row(children: [
            Text('${prod ? '● ' : ''}$name${n > 1 ? ' · $n panes' : ''}${ended ? ' · ended' : ''}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: color)),
            const SizedBox(width: 4),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => ws.closeTab(i),
              child: Tooltip(message: 'Close tab (ends its sessions)', child: Icon(Icons.close, size: 14, color: sel ? P.muted : P.line)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _node(TermTab t, PaneNode n) => switch (n) {
        PaneLeaf(:final pane) => _pane(t, pane),
        PaneSplit() => SplitView(split: n, ws: ws, a: _node(t, n.a), b: _node(t, n.b)),
      };

  Widget _pane(TermTab t, Pane p) {
    final s = p.session;
    final focused = t.focused == p;
    final many = t.panes.length > 1;
    final ended = s.exitCode != null;
    final quiet = !ended && s.linkState == linkReconnecting;
    final accent = s.local ? P.purple : P.teal;
    final h = s.host;
    final label = s.local
        ? 'local · $deviceName · sandboxed${widget.st.localShareNet ? ', network shared' : ', no network'}'
        : '${h.name}${s.title.isNotEmpty ? ' · ${visible(s.title, oneLine: true)}' : ''} · ${h.mode == Mode.pylon ? 'Pylon' : 'SSH'}';
    return Container(
      color: s.local ? P.localInk : P.ink2,
      child: Column(children: [
        Container(
          height: 30,
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: BoxDecoration(color: s.local ? P.purpleDeep : P.ink, border: Border(bottom: BorderSide(color: focused && many ? accent : (s.local ? P.purpleLine : P.ink)))),
          child: Row(children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: ended ? P.red : (quiet ? P.amber : accent), shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: focused ? (s.local ? P.localText : P.text) : (s.local ? P.localMuted : P.muted)))),
            if (ended) Text('Ended (${s.exitCode})  ', style: const TextStyle(fontSize: 12, color: P.red)),
            if (quiet) const Text('Reconnecting…  ', style: TextStyle(fontSize: 12, color: P.amber)),
            IconButton(
              tooltip: 'Close pane (Ctrl+Shift+W)',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, color: s.local ? P.localMuted : P.muted),
              onPressed: () => ws.closePane(p),
            ),
          ]),
        ),
        SessionNote(session: s, padding: 10, st: widget.st),
        // Connecting again opens a tab in this pane's place.
        LinkNote(
          session: s,
          padding: 10,
          onReconnect: () {
            final k = s.resumable ? s.keptSession : null;
            if (open(s.host, attach: k) != null) ws.closePane(p);
          },
        ),
        Expanded(
          child: TermView(
            key: _viewKey(p),
            screen: s.screen,
            scrollback: s.scrollback,
            fontSize: 14,
            cursor: accent,
            autofocus: focused,
            reserved: reserved,
            onFocused: () => ws.focus(p),
            onInput: s.input,
            onResize: s.resize,
          ),
        ),
      ]),
    );
  }

  Widget _statusBar() {
    final f = ws.focused;
    final st = widget.st;
    final List<String> facts;
    if (f == null) {
      facts = ['No terminal open', 'Ctrl+Shift+T new tab · Ctrl+Shift+L local shell'];
    } else if (f.session.local) {
      facts = [
        'Local shell: its own namespaces and home directory',
        st.localShareNet ? 'Network shared with this computer' : 'No network',
        "Can't reach Pylon's files, agent or sessions",
      ];
    } else {
      final h = f.session.host;
      final pin = st.pinFor(h);
      final key = pin == null ? 'host certificate' : '${pin.alg.replaceAll('ssh-', '').replaceAll('ecdsa-sha2-nistp256', 'ecdsa')} pinned';
      facts = [
        h.mode == Mode.pylon ? 'Pylon v1 · ML-KEM-768 + X25519 · $key' : 'SSH · strict key exchange · $key',
        st.obfuscateKeys ? 'Keystroke timing hidden' : 'Keystrokes sent as typed',
        'Emulator runs in its own sandboxed process',
      ];
    }
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(color: P.surface, border: Border(top: BorderSide(color: P.line))),
      child: Row(children: [
        for (final t in facts) Padding(padding: const EdgeInsets.only(right: 20), child: Text(t, style: const TextStyle(fontSize: 12, color: P.muted))),
      ]),
    );
  }

  Widget _empty() => Center(
        child: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [PylonMark(size: 32), SizedBox(width: 12), Text('No terminals open', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600))]),
            const SizedBox(height: 16),
            Card2(padding: EdgeInsets.zero, child: PaletteList(st: widget.st, canSplit: false, onChoice: (c) => c.manage ? _manage() : open(c.host!, where: c.where))),
          ]),
        ),
      );
}

/// Two panes and the divider between them, which can be dragged.
class SplitView extends StatelessWidget {
  const SplitView({super.key, required this.split, required this.ws, required this.a, required this.b});
  final PaneSplit split;
  final Workspace ws;
  final Widget a, b;

  static const _grip = 5.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final across = split.dir == SplitDir.right;
        final total = (across ? c.maxWidth : c.maxHeight) - _grip;
        final first = (total * split.ratio).clamp(0.0, total);
        final divider = MouseRegion(
          cursor: across ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => ws.setRatio(split, split.ratio + (across ? d.delta.dx : d.delta.dy) / (total <= 0 ? 1 : total)),
            child: SizedBox(
              width: across ? _grip : null,
              height: across ? null : _grip,
              child: Center(child: Container(width: across ? 1 : null, height: across ? null : 1, color: P.line)),
            ),
          ),
        );
        return Flex(direction: across ? Axis.horizontal : Axis.vertical, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(width: across ? first : null, height: across ? null : first, child: a),
          divider,
          Expanded(child: b),
        ]);
      });
}

/// The command palette: the local shell and every host, each to open in a
/// new tab or beside the focused pane.
class Palette extends StatelessWidget {
  const Palette({super.key, required this.st, required this.canSplit});
  final AppState st;
  final bool canSplit;

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: P.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: P.line)),
        child: SizedBox(width: 560, child: PaletteList(st: st, canSplit: canSplit, autofocus: true, onChoice: (c) => Navigator.pop(context, c))),
      );
}

class PaletteList extends StatefulWidget {
  const PaletteList({super.key, required this.st, required this.canSplit, required this.onChoice, this.autofocus = false});
  final AppState st;
  final bool canSplit, autofocus;
  final void Function(Choice c) onChoice;

  @override
  State<PaletteList> createState() => _PaletteListState();
}

class _PaletteListState extends State<PaletteList> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final hosts = [
      if (st.backend.hasLocalShell) Host.local(),
      for (final h in st.hosts)
        if (q.isEmpty || h.name.contains(q) || h.address.contains(q)) h,
    ].where((h) => !h.local || q.isEmpty || 'local shell'.contains(q.toLowerCase())).toList();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          autofocus: widget.autofocus,
          decoration: const InputDecoration(hintText: 'Open a host or the local shell'),
          onChanged: (v) => setState(() => q = v),
          onSubmitted: (_) {
            if (hosts.isNotEmpty) widget.onChoice(Choice(hosts.first, null));
          },
        ),
      ),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ListView(shrinkWrap: true, children: [
          for (final h in hosts) _row(h),
          ListTile(
            leading: const Icon(Icons.settings_outlined, color: P.muted),
            title: const Text('Hosts and settings'),
            subtitle: const Text('Add, edit and pin hosts; trusted CAs', style: TextStyle(color: P.muted, fontSize: 12)),
            onTap: () => widget.onChoice(const Choice(null, null, manage: true)),
          ),
        ]),
      ),
    ]);
  }

  Widget _row(Host h) {
    final pinned = h.local || widget.st.pinFor(h) != null;
    return ListTile(
      leading: Icon(h.local ? Icons.computer : Icons.dns_outlined, color: h.local ? P.purple : (pinned ? P.teal : P.amber)),
      title: Text(h.local ? 'Local shell' : h.name, style: TextStyle(color: h.local ? P.purple : P.text)),
      subtitle: Text(h.local ? 'This computer · sandboxed, no keys' : (pinned ? h.target : '${h.target} · not pinned'), style: const TextStyle(fontFamily: mono, fontSize: 12, color: P.muted)),
      onTap: () => widget.onChoice(Choice(h, null)),
      trailing: widget.canSplit && pinned
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Split right', icon: const Icon(Icons.vertical_split_outlined, color: P.muted), onPressed: () => widget.onChoice(Choice(h, SplitDir.right))),
              IconButton(tooltip: 'Split down', icon: const Icon(Icons.horizontal_split_outlined, color: P.muted), onPressed: () => widget.onChoice(Choice(h, SplitDir.down))),
            ])
          : null,
    );
  }
}
