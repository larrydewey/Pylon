import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../backend/model.dart';

/// Tabs and splits for the Linux desktop (SPEC 15): each tab is a tree
/// of panes, each pane one session. Closing a pane ends its session; a
/// tab whose last pane closes goes. Pure state, no widgets, so it can be
/// tested on its own.

/// Which way a split goes: [right] puts the new pane beside the focused
/// one (a vertical divider), [down] below it (a horizontal one).
enum SplitDir { right, down }

/// Moving the focus between panes.
enum Dir { left, right, up, down }

class Pane {
  Pane(this.id, this.session);
  final int id;
  final Session session;

  @override
  String toString() => 'Pane($id)';
}

sealed class PaneNode {}

class PaneLeaf extends PaneNode {
  PaneLeaf(this.pane);
  final Pane pane;
}

class PaneSplit extends PaneNode {
  PaneSplit(this.dir, this.a, this.b, {this.ratio = 0.5});
  final SplitDir dir;
  PaneNode a, b;

  /// The first child's share of the space, 0.1 to 0.9.
  double ratio;
}

class TermTab {
  TermTab(Pane p)
      : root = PaneLeaf(p),
        focused = p;
  PaneNode root;
  Pane focused;

  /// The panes, left to right and top to bottom.
  List<Pane> get panes => _panes(root, []);

  static List<Pane> _panes(PaneNode n, List<Pane> acc) {
    switch (n) {
      case PaneLeaf(:final pane):
        acc.add(pane);
      case PaneSplit(:final a, :final b):
        _panes(a, acc);
        _panes(b, acc);
    }
    return acc;
  }

  /// Where each pane sits in [area].
  Map<Pane, Rect> rects([Rect area = const Rect.fromLTWH(0, 0, 1, 1)]) => _rects(root, area, {});

  static Map<Pane, Rect> _rects(PaneNode n, Rect r, Map<Pane, Rect> acc) {
    switch (n) {
      case PaneLeaf(:final pane):
        acc[pane] = r;
      case PaneSplit(:final dir, :final a, :final b, :final ratio):
        if (dir == SplitDir.right) {
          final w = r.width * ratio;
          _rects(a, Rect.fromLTWH(r.left, r.top, w, r.height), acc);
          _rects(b, Rect.fromLTWH(r.left + w, r.top, r.width - w, r.height), acc);
        } else {
          final h = r.height * ratio;
          _rects(a, Rect.fromLTWH(r.left, r.top, r.width, h), acc);
          _rects(b, Rect.fromLTWH(r.left, r.top + h, r.width, r.height - h), acc);
        }
    }
    return acc;
  }
}

class Workspace extends ChangeNotifier {
  /// [end] ends a pane's session when the pane closes.
  Workspace(this.end);
  final void Function(Session s) end;

  final List<TermTab> tabs = [];
  int active = 0;
  int _ids = 0;

  TermTab? get tab => tabs.isEmpty ? null : tabs[active];
  Pane? get focused => tab?.focused;

  /// A new tab holding [s], made the active one.
  Pane openTab(Session s) {
    final p = Pane(++_ids, s);
    tabs.add(TermTab(p));
    active = tabs.length - 1;
    notifyListeners();
    return p;
  }

  /// The focused pane split in two, [s] in the new half, which takes the
  /// focus. With no tab yet, a new tab.
  Pane split(SplitDir dir, Session s) {
    final t = tab;
    if (t == null) return openTab(s);
    final p = Pane(++_ids, s);
    final old = t.focused;
    t.root = _replace(t.root, old, PaneSplit(dir, PaneLeaf(old), PaneLeaf(p)));
    t.focused = p;
    notifyListeners();
    return p;
  }

  static PaneNode _replace(PaneNode n, Pane target, PaneNode with_) {
    switch (n) {
      case PaneLeaf(:final pane):
        return pane == target ? with_ : n;
      case PaneSplit():
        n.a = _replace(n.a, target, with_);
        n.b = _replace(n.b, target, with_);
        return n;
    }
  }

  /// Closes a pane and ends its session: its sibling takes its place and
  /// the focus; the tab goes with its last pane.
  void closePane(Pane p) {
    final ti = tabs.indexWhere((t) => t.panes.contains(p));
    if (ti < 0) return;
    end(p.session);
    final t = tabs[ti];
    if (t.root case PaneLeaf(:final pane) when pane == p) {
      _removeTab(ti);
    } else {
      _siblingAfterClose = null;
      t.root = _without(t.root, p)!;
      if (t.focused == p) t.focused = _siblingAfterClose ?? t.panes.first;
    }
    notifyListeners();
  }

  Pane? _siblingAfterClose;

  // The tree without the leaf for p; a split that loses a child becomes
  // its other child, whose first pane is noted to take the focus.
  PaneNode? _without(PaneNode n, Pane p) {
    switch (n) {
      case PaneLeaf(:final pane):
        return pane == p ? null : n;
      case PaneSplit():
        final a = _without(n.a, p), b = _without(n.b, p);
        if (a == null) {
          _siblingAfterClose = TermTab._panes(b!, []).first;
          return b;
        }
        if (b == null) {
          _siblingAfterClose = TermTab._panes(a, []).last;
          return a;
        }
        n.a = a;
        n.b = b;
        return n;
    }
  }

  /// Closes a tab, ending every session in it.
  void closeTab(int i) {
    if (i < 0 || i >= tabs.length) return;
    for (final p in tabs[i].panes) {
      end(p.session);
    }
    _removeTab(i);
    notifyListeners();
  }

  void _removeTab(int i) {
    tabs.removeAt(i);
    if (active > i || active >= tabs.length) active = tabs.isEmpty ? 0 : active - 1;
    if (active < 0) active = 0;
  }

  void select(int i) {
    if (i < 0 || i >= tabs.length || i == active) return;
    active = i;
    notifyListeners();
  }

  /// The next (+1) or previous (-1) tab, round.
  void cycle(int delta) {
    if (tabs.length < 2) return;
    active = (active + delta) % tabs.length;
    notifyListeners();
  }

  void focus(Pane p) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].panes.contains(p)) {
        if (tabs[i].focused == p && active == i) return;
        tabs[i].focused = p;
        active = i;
        notifyListeners();
        return;
      }
    }
  }

  /// The pane next to the focused one in direction [d]: of those that
  /// share an edge with it on that side, the one beside its middle.
  void move(Dir d) {
    final t = tab;
    if (t == null) return;
    final rs = t.rects();
    final r = rs[t.focused]!;
    const eps = 1e-9;
    Pane? best;
    var bestDist = double.infinity;
    for (final e in rs.entries) {
      if (e.key == t.focused) continue;
      final c = e.value;
      final beside = switch (d) {
        Dir.left => (c.right - r.left).abs() < eps && c.top < r.bottom - eps && c.bottom > r.top + eps,
        Dir.right => (c.left - r.right).abs() < eps && c.top < r.bottom - eps && c.bottom > r.top + eps,
        Dir.up => (c.bottom - r.top).abs() < eps && c.left < r.right - eps && c.right > r.left + eps,
        Dir.down => (c.top - r.bottom).abs() < eps && c.left < r.right - eps && c.right > r.left + eps,
      };
      if (!beside) continue;
      final dist = d == Dir.left || d == Dir.right ? (c.center.dy - r.center.dy).abs() : (c.center.dx - r.center.dx).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = e.key;
      }
    }
    if (best != null) {
      t.focused = best;
      notifyListeners();
    }
  }

  /// A divider dragged: the split's first share, kept within 0.1 to 0.9.
  void setRatio(PaneSplit s, double r) {
    s.ratio = r.clamp(0.1, 0.9);
    notifyListeners();
  }

  /// Ends every session (the window closes).
  void closeAll() {
    while (tabs.isNotEmpty) {
      closeTab(tabs.length - 1);
    }
  }
}
