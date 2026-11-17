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
/// click, a long press a right click, a one-finger drag after a short
/// rest a drag with the button held (selecting, in most programs), and a
/// swipe, a two-finger drag or the wheel the wheel. Turning
/// [mouse] off gives touch back to scrolling.
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
  /// before a press is a right click.
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
    if (!_mouseOn) return;
    final at = _cellAt(e.localPosition);
    if (e.kind == PointerDeviceKind.mouse) {
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
      _downAt = e.localPosition;
      _downCell = _last = at;
      _pressed = _spent = _armed = _swiping = false;
      _wheel = 0;
      _arm?.cancel();
      _long?.cancel();
      // A drag holds the button (and selects, in most programs) only after
      // the finger has rested a moment; a swipe before that scrolls.
      _arm = Timer(armHold, () {
        if (!mounted || _pressed || _spent || _swiping || _touches.length != 1) return;
        _armed = true;
        HapticFeedback.selectionClick();
      });
      _long = Timer(longHold, () {
        if (!mounted || _pressed || _spent || _swiping || _touches.length != 1) return;
        _spent = true;
        HapticFeedback.mediumImpact();
        _click(MouseEncoder.right, _downCell);
      });
      return;
    }
    // A second finger: the wheel from here on, the first touch let go.
    _arm?.cancel();
    _long?.cancel();
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
    if (!_mouseOn) return;
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
        WidgetsBinding.instance.addPostFrameCallback((_) => widget.onResize(rows, cols));
      }
      final sb = widget.scrollback;
      // The scrollback was cleared under a view scrolled back past it.
      if (sb != null && sb.total >= 0 && _offset > sb.total) _offset = sb.total;
      final shown = _offset > 0 && sb != null && !widget.screen.altScreen ? widget.screen.scrolledBack(sb, _offset) : widget.screen;
      final mouse = _mouseOn;
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
        onTap: focus,
        // While the program takes the mouse, drags are its (the Listener's).
        onVerticalDragStart: mouse
            ? null
            : (_) {
                _drag = 0;
                if (sb != null && sb.total < 0 && !widget.screen.altScreen) sb.request?.call(0, 0);
              },
        onVerticalDragUpdate: mouse ? null : (d) => _dragBy(d.delta.dy, cell.height),
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          onFocusChange: (has) {
            if (has) widget.onFocused?.call();
          },
          child: Stack(children: [
            Positioned.fill(child: Container(color: P.ink2, padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: CustomPaint(painter: _ScreenPainter(shown, cell, widget.fontSize, widget.cursor)))),
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
  _ScreenPainter(this.s, this.cell, this.fontSize, this.cursor);
  final Screen s;
  final Size cell;
  final double fontSize;
  final Color cursor;

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
  bool shouldRepaint(_ScreenPainter old) => !identical(old.s, s) || old.cell != cell || old.cursor != cursor;
}
