import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'keys.dart';
import 'screen.dart';

/// The 256-colour palette: the 16 ANSI colours (tuned to the app's ink
/// ground), the 6x6x6 cube and the grey ramp.
class Palette {
  static const _ansi = [
    0xFF1B1F27, 0xFFE06C75, 0xFF7FD962, 0xFFE5C07B, 0xFF6CA8F7, 0xFFC678DD, 0xFF4FD1C5, 0xFFC9D1DB,
    0xFF5C6370, 0xFFFF8A8A, 0xFF9BE57F, 0xFFF5D58B, 0xFF8AB4FF, 0xFFD69CF0, 0xFF7DE3D9, 0xFFFFFFFF,
  ];

  static Color of(int i, {required bool fg}) {
    if (i == 256) return fg ? const Color(0xFFD6DDE6) : P.ink2;
    if (i < 16) return Color(_ansi[i]);
    if (i < 232) {
      final n = i - 16;
      int lvl(int v) => v == 0 ? 0 : 55 + v * 40;
      return Color.fromARGB(255, lvl(n ~/ 36), lvl((n ~/ 6) % 6), lvl(n % 6));
    }
    final g = 8 + (i - 232) * 10;
    return Color.fromARGB(255, g, g, g);
  }
}

/// Draws a [Screen] and turns keys into bytes for the host. Ctrl and Alt
/// may be latched by the extra-keys row ([ctrl], [alt]).
///
/// A vertical drag (or the mouse wheel) scrolls: back through the
/// [scrollback] on the normal screen, fetching it from the emulator as it
/// goes; with arrow keys while a full-screen program has the alternate
/// screen up. Typing, or the button that appears while scrolled back,
/// returns to the live screen.
///
/// While the program asks for mouse reports ([Screen.mouseTrack]) and
/// [mouse] is on, touches and the mouse go to it instead: a tap is a
/// click, a one-finger drag after a short rest a drag with the button
/// held (selecting, in most programs), and a swipe, a two-finger drag or
/// the wheel the wheel. Turning [mouse] off gives touch back to scrolling.
///
/// A long press, mouse or not, starts Pylon's own selection of what is on
/// screen: the word under the finger, which a drag before letting go
/// extends; handles move either end, and its bar copies it (no prompt: the
/// principal copies it), selects all, or keeps it to the pane (tmux's
/// split lines and the panes beside it left out; [paneOnly]).
///
/// Focus sits on a hidden text field, so a soft keyboard or an input
/// method has somewhere to type into; keys it does not turn into text
/// (Enter, arrows, Ctrl and Alt chords) bubble up to this view first.
class TermView extends StatefulWidget {
  const TermView({super.key, required this.screen, required this.onInput, required this.onResize, this.fontSize = 13, this.ctrl = false, this.alt = false, this.onModsUsed, this.autofocus = false, this.onFocused, this.cursor = P.teal, this.reserved, this.scrollback, this.mouse = true});

  final Screen screen;

  /// The session's scrollback (null: no scrolling back).
  final Scrollback? scrollback;

  /// Touches and the mouse go to a program that asks for mouse reports.
  final bool mouse;
  final void Function(List<int> bytes) onInput;
  final void Function(int rows, int cols) onResize;
  final double fontSize;
  final bool ctrl, alt;
  final VoidCallback? onModsUsed;
  final bool autofocus;

  /// Called when this view takes the keyboard focus (a click, a tap).
  final VoidCallback? onFocused;

  /// The cursor's colour: teal for a host, purple for the local shell.
  final Color cursor;

  /// Keys the window keeps for itself (the desktop's shortcuts): never
  /// sent to the host.
  final bool Function(KeyEvent e)? reserved;

  @override
  State<TermView> createState() => TermViewState();
}

class TermViewState extends State<TermView> {
  final _focus = FocusNode(skipTraversal: true);
  final _textFocus = FocusNode();
  final _text = TextEditingController();
  int _rows = 0, _cols = 0;

  // Lines scrolled back from the live screen (0: live), and the part of a
  // line a drag or wheel has moved and not yet turned into one.
  int _offset = 0;
  double _drag = 0;

  int get offset => _offset;

  /// How long a finger rests before a drag holds the mouse button, and
  /// before a press starts a selection.
  static const armHold = Duration(milliseconds: 300), longHold = Duration(milliseconds: 700);

  // Touch as mouse. The touches down and where each is; where the first
  // one went down (position and cell); whether its button press has been
  // sent; the cell last reported; the timers of the hold that arms a drag
  // and of the long press; whether the hold armed a drag; whether this
  // touch is a swipe (it moved before the hold armed a drag: the wheel);
  // whether it is spent (a long press, or a second finger came); the part
  // of a line the wheel has moved; and the mouse's button held.
  final _touches = <int, Offset>{};
  Offset _downAt = Offset.zero;
  (int, int) _downCell = (0, 0), _last = (0, 0);
  bool _pressed = false, _spent = false, _armed = false, _swiping = false;
  Timer? _arm, _long;
  double _wheel = 0;
  int _button = MouseEncoder.left;
  Size _cellSize = const Size(8, 16);

  bool get _mouseOn => widget.mouse && widget.screen.mouseTrack != 0;

  /// A selection keeps to the pane it began in (the line drawing tmux
  /// splits a window with bounds it). Kept for every view while the app
  /// runs.
  static bool paneOnly = true;

  // Pylon's own selection: its two ends (cells of the screen shown), the
  // word a long press began on (row, first and last column), the pane it
  // began in, whether the finger that made it is still down, whether this
  // touch made it (its tap does not clear it), which end a handle drag
  // moves and that end's cell from where the finger went down, and the
  // screen shown.
  (int, int)? _selA, _selB;
  (int, int, int)? _selWord;
  (int, int, int, int) _pane = (0, 0, 0, 0);
  bool _selDragging = false, _selMade = false, _dragA = false;
  Offset _handle = Offset.zero;
  Screen? _shown;

  bool get selecting => _selA != null;

  /// The text selected, as Copy takes it (null: no selection).
  String? get selection => _selA == null || _shown == null ? null : _shown!.textBetween(_selA!, _selB!, pane: paneOnly ? _pane : null);

  // Where an end shows: within the pane when the selection keeps to it.
  // The ends themselves stay where they were put, so turning Pane only
  // off gives back the rest.
  (int, int) _clip((int, int) c) => paneOnly ? (c.$1.clamp(_pane.$1, _pane.$3), c.$2.clamp(_pane.$2, _pane.$4)) : c;

  Offset _centre((int, int) c) => Offset(8 + (c.$1 + 0.5) * _cellSize.width, 4 + (c.$2 + 0.5) * _cellSize.height);

  void _select((int, int) c) {
    final s = _shown;
    if (s == null) return;
    HapticFeedback.mediumImpact();
    final pane = s.paneAt(c.$1, c.$2);
    final (ws, we) = s.wordAt(c.$1, c.$2, lo: pane.$1, hi: pane.$3);
    setState(() {
      _pane = pane;
      _selWord = (c.$2, ws, we);
      _selA = (ws, c.$2);
      _selB = (we, c.$2);
      _selDragging = _selMade = true;
    });
  }

  // The finger that made the selection moves: from the word to it.
  void _extend((int, int) c) {
    final w = _selWord!;
    final ws = (w.$2, w.$1), we = (w.$3, w.$1);
    final to = c;
    final before = to != ws && Screen.ordered(to, ws).$1 == to;
    setState(() {
      _selA = before ? to : ws;
      _selB = before ? we : Screen.ordered(to, we).$2;
    });
  }

  void clearSelection() {
    if (_selA == null) return;
    setState(() {
      _selA = _selB = null;
      _selWord = null;
      _selDragging = false;
    });
  }

  Future<void> _copy() async {
    final t = selection;
    if (t == null) return;
    clearSelection();
    await Clipboard.setData(ClipboardData(text: t));
  }

  void _selectAll() {
    final s = _shown;
    if (s == null) return;
    setState(() {
      _selA = paneOnly ? (_pane.$1, _pane.$2) : (0, 0);
      _selB = paneOnly ? (_pane.$3, _pane.$4) : (s.cols - 1, s.rows - 1);
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? focus() : null);
  }

  @override
  void dispose() {
    _arm?.cancel();
    _long?.cancel();
    _focus.dispose();
    _textFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  bool get hasFocus => _focus.hasFocus;

  Size _cell() {
    final tp = TextPainter(text: TextSpan(text: 'M', style: TextStyle(fontFamily: mono, fontSize: widget.fontSize, height: 1.25)), textDirection: TextDirection.ltr)..layout();
    return Size(tp.width, tp.height);
  }

  /// Takes the keyboard focus and shows the soft keyboard. When the hidden
  /// field already has the focus but the keyboard was put away (Back, or
  /// its own hide key), asking for the focus again does nothing, so the
  /// keyboard is asked for directly.
  void focus() {
    if (_textFocus.hasFocus) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      _textFocus.requestFocus();
    }
  }

  // Input goes to the host, and the view back to the live screen.
  void _send(List<int> bytes) {
    clearSelection();
    if (_offset != 0) {
      setState(() => _offset = 0);
    }
    widget.onInput(bytes);
  }

  void toLive() => setState(() => _offset = 0);

  // Moves by [lines] (positive: back, toward older output).
  void _scrollBy(int lines) {
    if (lines == 0) return;
    if (widget.screen.altScreen) {
      // A full-screen program: what a wheel does there in other terminals.
      final key = lines > 0 ? LogicalKeyboardKey.arrowUp : LogicalKeyboardKey.arrowDown;
      final b = KeyEncoder.encode(key, ctrl: false, alt: false, shift: false, appCursor: widget.screen.appCursor);
      if (b == null) return;
      for (var i = 0; i < lines.abs(); i++) {
        widget.onInput(b);
      }
      return;
    }
    final sb = widget.scrollback;
    if (sb == null) return;
    if (sb.total < 0) {
      sb.request?.call(0, 0); // how much there is; the next move scrolls
      return;
    }
    final next = (_offset + lines).clamp(0, sb.total);
    if (next != _offset) {
      setState(() => _offset = next);
    }
    _fetch();
  }

  // The scrollback lines in view (and a margin) that are not here yet.
  void _fetch() {
    final sb = widget.scrollback;
    if (sb == null || _offset == 0 || sb.total <= 0) return;
    final top = sb.total - _offset;
    final need = math.min(_rows, sb.total - top);
    if (need > 0 && !sb.has(top, need)) sb.request?.call(math.max(0, top - 200), 500);
  }

  void _dragBy(double dy, double lineHeight) {
    _drag += dy;
    final lines = _drag ~/ lineHeight;
    if (lines != 0) {
      _drag -= lines * lineHeight;
      _scrollBy(lines);
    }
  }

  (int, int) _cellAt(Offset p) {
    final s = widget.screen;
    final x = ((p.dx - 8) / _cellSize.width).floor().clamp(0, s.cols - 1);
    final y = ((p.dy - 4) / _cellSize.height).floor().clamp(0, s.rows - 1);
    return (x, y);
  }

  // A report to the program, with the modifiers held or latched.
  void _report(int button, (int, int) at, {bool release = false}) {
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed || widget.ctrl, alt = hk.isAltPressed || widget.alt;
    final mods = (hk.isShiftPressed ? MouseEncoder.shift : 0) | (alt ? MouseEncoder.meta : 0) | (ctrl ? MouseEncoder.ctrl : 0);
    final b = MouseEncoder.report(button | mods, at.$1, at.$2, sgr: widget.screen.mouseSgr, release: release);
    if (b == null) return;
    _send(b);
    if (widget.ctrl || widget.alt) widget.onModsUsed?.call();
  }

  void _click(int button, (int, int) at) {
    _report(button, at);
    _report(button, at, release: true);
  }

  void _wheelBy(int lines, (int, int) at) {
    for (var i = 0; i < lines.abs(); i++) {
      _report(lines > 0 ? MouseEncoder.wheelUp : MouseEncoder.wheelDown, at);
    }
  }

  void _down(PointerDownEvent e) {
    final at = _cellAt(e.localPosition);
    if (e.kind == PointerDeviceKind.mouse) {
      if (!_mouseOn) return;
      _button = e.buttons & kSecondaryMouseButton != 0
          ? MouseEncoder.right
          : e.buttons & kMiddleMouseButton != 0
              ? MouseEncoder.middle
              : MouseEncoder.left;
      _pressed = true;
      _last = at;
      _report(_button, at);
      return;
    }
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 1) {
      _selMade = false;
      _arm?.cancel();
      _long?.cancel();
      // With a selection up, a tap clears it and its handles move it.
      if (_selA != null) return;
      _downAt = e.localPosition;
      _downCell = _last = at;
      _pressed = _spent = _armed = _swiping = false;
      _wheel = 0;
      // A long press selects (below). A drag holds the button (and selects, in most programs) only after
      // the finger has rested a moment; a swipe before that scrolls.
      if (_mouseOn) {
        _arm = Timer(armHold, () {
          if (!mounted || _pressed || _spent || _swiping || _touches.length != 1) return;
          _armed = true;
          HapticFeedback.selectionClick();
        });
      }
      _long = Timer(longHold, () {
        if (!mounted || _pressed || _spent || _swiping || _touches.length != 1) return;
        _spent = true;
        _select(_downCell);
      });
      return;
    }
    // A second finger: the wheel from here on, the first touch let go.
    _arm?.cancel();
    _long?.cancel();
    _selDragging = false;
    if (!_mouseOn) return;
    if (_pressed) _report(MouseEncoder.left, _last, release: true);
    _pressed = false;
    _spent = true;
    _wheel = 0;
  }

  void _move(PointerMoveEvent e) {
    final at = _cellAt(e.localPosition);
    if (e.kind == PointerDeviceKind.mouse) {
      if (!_pressed || !_mouseOn) return;
      if (at != _last && widget.screen.mouseTrack >= 1002) _report(_button + MouseEncoder.motion, at);
      _last = at;
      return;
    }
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_selDragging && _touches.length == 1) {
      _extend(at);
      return;
    }
    if (_selA != null) return;
    if (!_mouseOn) {
      // Moved: a scroll, not a long press.
      if ((e.localPosition - _downAt).distance >= kTouchSlop) {
        _long?.cancel();
        _swiping = true;
      }
      return;
    }
    if (_touches.length >= 2) {
      _wheelDrag(e.delta.dy / _touches.length, at);
      return;
    }
    if (_spent) return;
    if (_swiping) {
      _wheelDrag(e.delta.dy, at);
      return;
    }
    if (!_pressed) {
      if ((e.localPosition - _downAt).distance < kTouchSlop) return;
      _arm?.cancel();
      _long?.cancel();
      if (!_armed) {
        // Moved before the hold armed a drag: a swipe, the wheel.
        _swiping = true;
        _wheelDrag(e.localPosition.dy - _downAt.dy, at);
        return;
      }
      _pressed = true;
      _report(MouseEncoder.left, _downCell);
    }
    if (at != _last && widget.screen.mouseTrack >= 1002) _report(MouseEncoder.left + MouseEncoder.motion, at);
    _last = at;
  }

  // Fingers down the screen bring older lines into view: wheel up.
  void _wheelDrag(double dy, (int, int) at) {
    _wheel += dy;
    final lines = _wheel ~/ _cellSize.height;
    if (lines != 0) {
      _wheel -= lines * _cellSize.height;
      _wheelBy(lines, at);
    }
  }

  void _up(PointerEvent e, {bool cancel = false}) {
    if (e.kind == PointerDeviceKind.mouse) {
      if (_pressed && _mouseOn) _report(_button, _cellAt(e.localPosition), release: true);
      _pressed = false;
      return;
    }
    if (_touches.remove(e.pointer) == null || _touches.isNotEmpty) return;
    _selDragging = false;
    _arm?.cancel();
    _long?.cancel();
    final pressed = _pressed, spent = _spent || _swiping;
    _pressed = false;
    _spent = true;
    if (!_mouseOn) return;
    if (pressed) {
      _report(MouseEncoder.left, _last, release: true);
    } else if (!spent && !cancel) {
      _click(MouseEncoder.left, _downCell);
    }
  }

  void _hover(PointerHoverEvent e) {
    if (!_mouseOn || widget.screen.mouseTrack != 1003) return;
    final at = _cellAt(e.localPosition);
    if (at == _last) return;
    _last = at;
    _report(MouseEncoder.none + MouseEncoder.motion, at);
  }

  // A handle at the start (left of its cell) or end (right) of the
  // selection; dragging it moves that end.
  Widget _handleFor(bool start, (int, int) c, Size cell) {
    const r = 11.0;
    final isA = (Screen.ordered(_selA!, _selB!).$1 == _selA) == start;
    final x = 8 + (c.$1 + (start ? 0 : 1)) * cell.width, y = 4 + (c.$2 + 1) * cell.height;
    return Positioned(
      left: x - r - 8,
      top: y - 8,
      width: 2 * r + 16,
      height: 2 * r + 16,
      child: GestureDetector(
        key: Key(start ? 'sel-start' : 'sel-end'),
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        onPanDown: (d) {
          _dragA = isA;
          _handle = _centre(_clip(isA ? _selA! : _selB!)) - d.globalPosition;
        },
        onPanUpdate: (d) {
          final to = _cellAt(_handle + d.globalPosition);
          setState(() => _dragA ? _selA = to : _selB = to);
        },
        child: Center(
          child: Container(
            width: 2 * r,
            height: 2 * r,
            decoration: BoxDecoration(
              color: P.teal,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(start ? r : 0),
                topRight: Radius.circular(start ? 0 : r),
                bottomLeft: const Radius.circular(r),
                bottomRight: const Radius.circular(r),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Copy, select all, keep to the pane, close: above the selection, or
  // below it when it starts near the top.
  Widget _selectionBar(((int, int), (int, int)) sel, Size cell, double height) {
    const h = 40.0;
    final above = 4 + sel.$1.$2 * cell.height - h - 6;
    final below = 4 + (sel.$2.$2 + 1) * cell.height + 30;
    final top = above >= 0 ? above : math.min(below, math.max(0.0, height - h));
    Widget act(String key, String label, VoidCallback onTap, {IconData? icon}) => TextButton.icon(
          key: Key(key),
          onPressed: onTap,
          icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 16),
          label: Text(label),
          style: TextButton.styleFrom(foregroundColor: P.tealText, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, h)),
        );
    return Positioned(
      left: 8,
      right: 8,
      top: top,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: P.surface,
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: P.line)),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              act('sel-copy', 'Copy', _copy, icon: Icons.copy),
              act('sel-all', 'All', _selectAll),
              Semantics(
                toggled: paneOnly,
                child: act('sel-pane', 'Pane only', () => setState(() => paneOnly = !paneOnly), icon: paneOnly ? Icons.check_box : Icons.check_box_outline_blank),
              ),
              IconButton(key: const Key('sel-cancel'), tooltip: 'Clear the selection', onPressed: clearSelection, icon: const Icon(Icons.close, size: 18, color: P.muted)),
            ]),
          ),
        ),
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (widget.reserved?.call(e) ?? false) return KeyEventResult.handled;
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed || widget.ctrl;
    final alt = hk.isAltPressed || widget.alt;
    final shift = hk.isShiftPressed;
    final special = KeyEncoder.encode(e.logicalKey, ctrl: ctrl, alt: alt, shift: shift, appCursor: widget.screen.appCursor);
    if (special != null) {
      _send(special);
      widget.onModsUsed?.call();
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (ch != null && ch.isNotEmpty && (ctrl || alt)) {
      _send(KeyEncoder.text(ch, ctrl: ctrl, alt: alt));
      widget.onModsUsed?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cell = _cell();
    _cellSize = cell;
    return LayoutBuilder(builder: (context, c) {
      final cols = math.max(10, (c.maxWidth - 16) ~/ cell.width);
      final rows = math.max(4, (c.maxHeight - 8) ~/ cell.height);
      if (rows != _rows || cols != _cols) {
        _rows = rows;
        _cols = cols;
        _selA = _selB = null;
        _selDragging = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => widget.onResize(rows, cols));
      }
      final sb = widget.scrollback;
      // The scrollback was cleared under a view scrolled back past it.
      if (sb != null && sb.total >= 0 && _offset > sb.total) _offset = sb.total;
      final shown = _offset > 0 && sb != null && !widget.screen.altScreen ? widget.screen.scrolledBack(sb, _offset) : widget.screen;
      _shown = shown;
      final mouse = _mouseOn;
      final sel = _selA == null ? null : Screen.ordered(_selA!, _selB!);
      return Listener(
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent) return;
          if (mouse) {
            // One report a notch, as xterm sends.
            if (e.scrollDelta.dy != 0) _wheelBy(e.scrollDelta.dy < 0 ? 1 : -1, _cellAt(e.localPosition));
          } else {
            _dragBy(-e.scrollDelta.dy, cell.height);
          }
        },
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (e) => _up(e, cancel: true),
        onPointerHover: _hover,
        child: GestureDetector(
        onTap: () {
          if (_selMade) return; // the long press that made the selection
          if (_selA != null) return clearSelection();
          focus();
        },
        // While the program takes the mouse, drags are its (the Listener's);
        // while a selection is up, its handles'.
        onVerticalDragStart: mouse || sel != null
            ? null
            : (_) {
                _drag = 0;
                if (sb != null && sb.total < 0 && !widget.screen.altScreen) sb.request?.call(0, 0);
              },
        onVerticalDragUpdate: mouse || sel != null
            ? null
            : (d) {
                if (_selA == null) _dragBy(d.delta.dy, cell.height);
              },
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          onFocusChange: (has) {
            if (has) widget.onFocused?.call();
          },
          child: Stack(children: [
            Positioned.fill(child: Container(color: P.ink2, padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: CustomPaint(painter: _ScreenPainter(shown, cell, widget.fontSize, widget.cursor, sel, paneOnly ? _pane : null)))),
            if (sel != null) ...[
              _handleFor(true, _clip(sel.$1), cell),
              _handleFor(false, _clip(sel.$2), cell),
              _selectionBar(sel, cell, c.maxHeight),
            ],
            if (_offset > 0)
              Positioned(
                right: 12,
                bottom: 12,
                child: Semantics(
                  label: 'Back to the live screen',
                  button: true,
                  child: Material(
                    color: P.surface,
                    shape: const StadiumBorder(side: BorderSide(color: P.tealLine)),
                    child: InkWell(
                      key: const Key('to-live'),
                      customBorder: const StadiumBorder(),
                      onTap: toLive,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text('$_offset ↑', style: const TextStyle(fontFamily: mono, fontSize: 12, color: P.muted)),
                          const SizedBox(width: 6),
                          const Icon(Icons.arrow_downward, size: 16, color: P.tealText),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            // Typed text arrives here (soft keyboards): sent at once and
            // cleared, with suggestions and learning off (SPEC 15).
            Positioned(
              left: 0,
              bottom: 0,
              width: 1,
              height: 1,
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: _text,
                  focusNode: _textFocus,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.visiblePassword,
                  onChanged: (v) {
                    if (v.isEmpty) return;
                    _send(KeyEncoder.text(v, ctrl: widget.ctrl, alt: widget.alt));
                    widget.onModsUsed?.call();
                    _text.clear();
                  },
                  onSubmitted: (_) => _send([13]),
                ),
              ),
            ),
          ]),
        ),
        ),
      );
    });
  }
}

class _ScreenPainter extends CustomPainter {
  _ScreenPainter(this.s, this.cell, this.fontSize, this.cursor, this.sel, this.pane);
  final Screen s;
  final Size cell;
  final double fontSize;
  final Color cursor;

  // The selection, in reading order, and the pane it keeps to (null: none).
  final ((int, int), (int, int))? sel;
  final (int, int, int, int)? pane;

  bool _selected(int x, int y) {
    final v = sel;
    if (v == null) return false;
    final (a, b) = v;
    if (y < a.$2 || y > b.$2 || (y == a.$2 && x < a.$1) || (y == b.$2 && x > b.$1)) return false;
    final p = pane;
    return p == null || (x >= p.$1 && x <= p.$3 && y >= p.$2 && y <= p.$4);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (var y = 0; y < s.rows; y++) {
      for (var x = 0; x < s.cols; x++) {
        final i = y * s.cols + x;
        final a = s.attr[i];
        var fg = Palette.of(A.fg(a), fg: true);
        var bg = Palette.of(A.bg(a), fg: false);
        if (A.inverse(a)) {
          final t = fg;
          fg = bg;
          bg = t;
        }
        final cursorHere = s.cursorVisible && x == s.cx && y == s.cy;
        if (cursorHere) {
          bg = cursor;
          fg = P.ink2;
        }
        if (_selected(x, y)) bg = Color.alphaBlend(P.teal.withValues(alpha: 0.45), bg);
        final r = Rect.fromLTWH(x * cell.width, y * cell.height, cell.width + 0.5, cell.height + 0.5);
        if (bg != P.ink2) canvas.drawRect(r, Paint()..color = bg);
        final c = s.cp[i];
        if (c > 32 && !A.hidden(a)) {
          final tp = TextPainter(
            text: TextSpan(
              text: String.fromCharCode(c),
              style: TextStyle(
                fontFamily: mono,
                fontSize: fontSize,
                height: 1.25,
                color: A.dim(a) ? fg.withValues(alpha: 0.6) : fg,
                fontWeight: A.bold(a) ? FontWeight.w700 : FontWeight.w400,
                fontStyle: A.italic(a) ? FontStyle.italic : FontStyle.normal,
                decoration: TextDecoration.combine([if (A.underline(a)) TextDecoration.underline, if (A.strike(a)) TextDecoration.lineThrough]),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(x * cell.width, y * cell.height));
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ScreenPainter old) => !identical(old.s, s) || old.cell != cell || old.cursor != cursor || old.sel != sel || old.pane != pane;
}
