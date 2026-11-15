import 'dart:typed_data';

/// One screen from pylon-term (frame type 1): size, cursor, modes and a
/// code point and attribute word per cell, exactly as the confined
/// emulator computed them. The app never parses host output itself.
class Screen {
  Screen(this.rows, this.cols, this.cx, this.cy, this.modes, this.cp, this.attr);

  final int rows, cols, cx, cy, modes;
  final Uint32List cp;
  final Uint32List attr;

  static Screen blank(int rows, int cols) =>
      Screen(rows, cols, 0, 0, 3, Uint32List(rows * cols)..fillRange(0, rows * cols, 32), Uint32List(rows * cols)..fillRange(0, rows * cols, attrDefault));

  static const attrDefault = 256 | (256 << 9);

  bool get cursorVisible => modes & 2 != 0;
  bool get bracketedPaste => modes & 4 != 0;
  bool get appCursor => modes & 8 != 0;

  /// Decodes a type-1 payload; null when it is malformed.
  static Screen? decode(Uint8List p) {
    if (p.length < 12) return null;
    final b = ByteData.sublistView(p);
    final rows = b.getUint16(0), cols = b.getUint16(2), cx = b.getUint16(4), cy = b.getUint16(6), modes = b.getUint32(8);
    final n = rows * cols;
    if (rows == 0 || cols == 0 || p.length != 12 + n * 8) return null;
    final cp = Uint32List(n), attr = Uint32List(n);
    for (var i = 0; i < n; i++) {
      cp[i] = b.getUint32(12 + i * 8);
      attr[i] = b.getUint32(16 + i * 8);
    }
    return Screen(rows, cols, cx, cy, modes, cp, attr);
  }

  String rowText(int y) {
    final sb = StringBuffer();
    for (var x = 0; x < cols; x++) {
      final c = cp[y * cols + x];
      if (c != 0) sb.writeCharCode(c);
    }
    return sb.toString().trimRight();
  }
}

/// Attribute bits (core/term.resid).
class A {
  static int fg(int a) => a & 511;
  static int bg(int a) => (a >> 9) & 511;
  static bool bold(int a) => a & (1 << 18) != 0;
  static bool dim(int a) => a & (1 << 19) != 0;
  static bool italic(int a) => a & (1 << 20) != 0;
  static bool underline(int a) => a & (1 << 21) != 0;
  static bool inverse(int a) => a & (1 << 23) != 0;
  static bool hidden(int a) => a & (1 << 24) != 0;
  static bool strike(int a) => a & (1 << 25) != 0;
}
