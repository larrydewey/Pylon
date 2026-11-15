import 'dart:math' as math;

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
class TermView extends StatefulWidget {
  const TermView({super.key, required this.screen, required this.onInput, required this.onResize, this.fontSize = 13, this.ctrl = false, this.alt = false, this.onModsUsed});

  final Screen screen;
  final void Function(List<int> bytes) onInput;
  final void Function(int rows, int cols) onResize;
  final double fontSize;
  final bool ctrl, alt;
  final VoidCallback? onModsUsed;

  @override
  State<TermView> createState() => TermViewState();
}

class TermViewState extends State<TermView> {
  final _focus = FocusNode();
  final _text = TextEditingController();
  int _rows = 0, _cols = 0;

  Size _cell() {
    final tp = TextPainter(text: TextSpan(text: 'M', style: TextStyle(fontFamily: mono, fontSize: widget.fontSize, height: 1.25)), textDirection: TextDirection.ltr)..layout();
    return Size(tp.width, tp.height);
  }

  void focus() => _focus.requestFocus();

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed || widget.ctrl;
    final alt = hk.isAltPressed || widget.alt;
    final shift = hk.isShiftPressed;
    final special = KeyEncoder.encode(e.logicalKey, ctrl: ctrl, alt: alt, shift: shift, appCursor: widget.screen.appCursor);
    if (special != null) {
      widget.onInput(special);
      widget.onModsUsed?.call();
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (ch != null && ch.isNotEmpty && (ctrl || alt)) {
      widget.onInput(KeyEncoder.text(ch, ctrl: ctrl, alt: alt));
      widget.onModsUsed?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cell = _cell();
    return LayoutBuilder(builder: (context, c) {
      final cols = math.max(10, (c.maxWidth - 16) ~/ cell.width);
      final rows = math.max(4, (c.maxHeight - 8) ~/ cell.height);
      if (rows != _rows || cols != _cols) {
        _rows = rows;
        _cols = cols;
        WidgetsBinding.instance.addPostFrameCallback((_) => widget.onResize(rows, cols));
      }
      return GestureDetector(
        onTap: focus,
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Stack(children: [
            Positioned.fill(child: Container(color: P.ink2, padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: CustomPaint(painter: _ScreenPainter(widget.screen, cell, widget.fontSize)))),
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
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.visiblePassword,
                  onChanged: (v) {
                    if (v.isEmpty) return;
                    widget.onInput(KeyEncoder.text(v, ctrl: widget.ctrl, alt: widget.alt));
                    widget.onModsUsed?.call();
                    _text.clear();
                  },
                  onSubmitted: (_) => widget.onInput([13]),
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }
}

class _ScreenPainter extends CustomPainter {
  _ScreenPainter(this.s, this.cell, this.fontSize);
  final Screen s;
  final Size cell;
  final double fontSize;

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
          bg = P.teal;
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
  bool shouldRepaint(_ScreenPainter old) => !identical(old.s, s) || old.cell != cell;
}
