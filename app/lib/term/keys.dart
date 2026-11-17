import 'dart:convert';

import 'package:flutter/services.dart';

/// What a key sends to the host, xterm-style. Ctrl and Alt can also be
/// latched from the extra-keys row.
class KeyEncoder {
  static List<int>? encode(LogicalKeyboardKey k, {required bool ctrl, required bool alt, required bool shift, required bool appCursor}) {
    final arrows = {
      LogicalKeyboardKey.arrowUp: 'A',
      LogicalKeyboardKey.arrowDown: 'B',
      LogicalKeyboardKey.arrowRight: 'C',
      LogicalKeyboardKey.arrowLeft: 'D',
    };
    if (arrows.containsKey(k)) {
      final mod = _mod(ctrl, alt, shift);
      if (mod > 1) return utf8.encode('\x1b[1;$mod${arrows[k]}');
      return utf8.encode(appCursor ? '\x1bO${arrows[k]}' : '\x1b[${arrows[k]}');
    }
    final simple = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.enter: '\r',
      LogicalKeyboardKey.numpadEnter: '\r',
      LogicalKeyboardKey.backspace: '\x7f',
      LogicalKeyboardKey.tab: shift ? '\x1b[Z' : '\t',
      LogicalKeyboardKey.escape: '\x1b',
      LogicalKeyboardKey.home: '\x1b[H',
      LogicalKeyboardKey.end: '\x1b[F',
      LogicalKeyboardKey.pageUp: '\x1b[5~',
      LogicalKeyboardKey.pageDown: '\x1b[6~',
      LogicalKeyboardKey.insert: '\x1b[2~',
      LogicalKeyboardKey.delete: '\x1b[3~',
      LogicalKeyboardKey.f1: '\x1bOP',
      LogicalKeyboardKey.f2: '\x1bOQ',
      LogicalKeyboardKey.f3: '\x1bOR',
      LogicalKeyboardKey.f4: '\x1bOS',
    };
    final s = simple[k];
    if (s != null) return utf8.encode(alt ? '\x1b$s' : s);
    return null;
  }

  /// A typed character, with latched Ctrl / Alt applied.
  static List<int> text(String t, {required bool ctrl, required bool alt}) {
    if (ctrl && t.length == 1) {
      final c = t.toLowerCase().codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) return [if (alt) 0x1b, c - 0x60];
      if (c == 0x20 || c == 0x40) return [if (alt) 0x1b, 0];
      if (c >= 0x5b && c <= 0x5f) return [if (alt) 0x1b, c - 0x40];
    }
    return [if (alt) 0x1b, ...utf8.encode(t)];
  }

  static int _mod(bool ctrl, bool alt, bool shift) => 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);

  /// A paste: inside bracketed paste markers when the program asked for
  /// them, with any marker inside the text removed (it could end the paste
  /// early and run what follows), SPEC 12.
  static List<int> paste(String t, {required bool bracketed}) {
    final clean = t.replaceAll('\x1b[200~', '').replaceAll('\x1b[201~', '');
    final body = utf8.encode(clean.replaceAll('\r\n', '\r').replaceAll('\n', '\r'));
    return bracketed ? [...utf8.encode('\x1b[200~'), ...body, ...utf8.encode('\x1b[201~')] : body;
  }

  /// Whether a paste needs the principal's confirmation first: it holds a
  /// line break or control characters and the program did not ask for
  /// bracketed paste (SPEC 12).
  static bool pasteNeedsConfirm(String t, {required bool bracketed}) {
    if (bracketed) return t.contains('\x1b[201~');
    return t.codeUnits.any((c) => c < 0x20 && c != 0x09);
  }
}

/// Mouse reports for a program that asked for them (DECSET 1000, 1002,
/// 1003), in the encoding it asked for: SGR (1006) or X10 bytes.
class MouseEncoder {
  static const left = 0, middle = 1, right = 2, wheelUp = 64, wheelDown = 65;

  /// Added to a button for motion (a drag, or a move with none held).
  static const motion = 32;

  /// The button code of motion with no button held.
  static const none = 3;

  /// Modifier bits.
  static const shift = 4, meta = 8, ctrl = 16;

  /// A report of [button] (with [motion] and modifier bits) at the cell
  /// [x], [y] (from 0): a press or motion, or with [release] a release.
  /// Null where X10 bytes cannot hold the position (beyond 223).
  static List<int>? report(int button, int x, int y, {required bool sgr, bool release = false}) {
    if (sgr) return utf8.encode('\x1b[<$button;${x + 1};${y + 1}${release ? 'm' : 'M'}');
    if (x > 222 || y > 222) return null;
    // X10 has no button in a release: button 3, the modifiers kept.
    final b = release ? (none | (button & (shift | meta | ctrl))) : button;
    return [27, 91, 77, 32 + b, 33 + x, 33 + y];
  }
}
