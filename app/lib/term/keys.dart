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
