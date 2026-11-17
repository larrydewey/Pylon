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

  /// A full-screen program has the alternate screen up (cli/pylon_term.resid
  /// bit 128): scrolling sends it arrow keys; the scrollback is not its.
  bool get altScreen => modes & 128 != 0;

  /// The mouse reports the program asked for (core/term.resid's bits): 0
  /// none, 1000 presses and releases, 1002 also drags, 1003 also motion
  /// with no button held.
  int get mouseTrack => modes & 1024 != 0
      ? 1003
      : modes & 512 != 0
          ? 1002
          : modes & 256 != 0
              ? 1000
              : 0;

  /// Mouse reports in the SGR encoding (1006) rather than X10 bytes.
  bool get mouseSgr => modes & 2048 != 0;

  /// What is seen [offset] lines up from the live screen: the scrollback's
  /// lines from `total - offset` on (from [sb], blank where it has not
  /// fetched them yet), then the screen's top rows. No cursor.
  Screen scrolledBack(Scrollback sb, int offset) {
    if (offset <= 0 || sb.total <= 0) return this;
    final n = rows * cols;
    final cp2 = Uint32List(n)..fillRange(0, n, 32);
    final at2 = Uint32List(n)..fillRange(0, n, attrDefault);
    final top = sb.total - offset;
    for (var y = 0; y < rows; y++) {
      final line = top + y;
      if (line < sb.total) {
        final r = sb.at(line);
        if (r == null) continue;
        final w = r.cp.length < cols ? r.cp.length : cols;
        for (var x = 0; x < w; x++) {
          cp2[y * cols + x] = r.cp[x];
          at2[y * cols + x] = r.attr[x];
        }
      } else {
        final sy = line - sb.total;
        if (sy >= rows) break;
        cp2.setRange(y * cols, y * cols + cols, cp, sy * cols);
        at2.setRange(y * cols, y * cols + cols, attr, sy * cols);
      }
    }
    return Screen(rows, cols, cx, cy, modes & ~2, cp2, at2);
  }

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

  int at(int x, int y) => cp[y * cols + x];

  // Line drawing that splits panes (tmux, screen): what stops a pane
  // across (a vertical line, or a corner or junction on one) and down.
  static bool _stopsAcross(int c) => const {0x2502, 0x2503, 0x2551, 0x251C, 0x2524, 0x253C, 0x252C, 0x2534, 0x250C, 0x2510, 0x2514, 0x2518, 0x2523, 0x252B, 0x254B}.contains(c);
  static bool _stopsDown(int c) => const {0x2500, 0x2501, 0x2550, 0x251C, 0x2524, 0x253C, 0x252C, 0x2534, 0x250C, 0x2510, 0x2514, 0x2518, 0x2523, 0x252B, 0x254B}.contains(c);

  /// The pane around the cell at [x], [y]: left, top, right and bottom
  /// (inclusive), bounded by the line drawing that splits a terminal
  /// into panes, or the screen's edges. A cell on a border is its own pane.
  (int, int, int, int) paneAt(int x, int y) {
    if (_stopsAcross(at(x, y)) || _stopsDown(at(x, y))) return (x, y, x, y);
    var l = x, r = x, t = y, b = y;
    while (l > 0 && !_stopsAcross(at(l - 1, y))) {
      l--;
    }
    while (r < cols - 1 && !_stopsAcross(at(r + 1, y))) {
      r++;
    }
    while (t > 0 && !_stopsDown(at(x, t - 1))) {
      t--;
    }
    while (b < rows - 1 && !_stopsDown(at(x, b + 1))) {
      b++;
    }
    return (l, t, r, b);
  }

  /// The word at [x], [y] (a run of non-blank cells, within [lo]..[hi]):
  /// its first and last column. A blank cell is a word of its own.
  (int, int) wordAt(int x, int y, {int lo = 0, int? hi}) {
    final h = hi ?? cols - 1;
    bool word(int c) => c > 32 && !_stopsAcross(c);
    if (!word(at(x, y))) return (x, x);
    var s = x, e = x;
    while (s > lo && word(at(s - 1, y))) {
      s--;
    }
    while (e < h && word(at(e + 1, y))) {
      e++;
    }
    return (s, e);
  }

  /// The text from cell [a] to cell [b] (either order), inclusive, a line
  /// a row with trailing blanks dropped. Within [pane] (left, top, right,
  /// bottom) when given: each row only its columns, rows outside it none.
  String textBetween((int, int) a, (int, int) b, {(int, int, int, int)? pane}) {
    final (s, e) = ordered(a, b);
    final (pl, pt, pr, pb) = pane ?? (0, 0, cols - 1, rows - 1);
    final lines = <String>[];
    for (var y = s.$2; y <= e.$2; y++) {
      if (y < pt || y > pb) continue;
      final from = y == s.$2 ? s.$1 : 0, to = y == e.$2 ? e.$1 : cols - 1;
      final sb = StringBuffer();
      for (var x = from < pl ? pl : from; x <= (to > pr ? pr : to); x++) {
        final c = at(x, y);
        if (c != 0) sb.writeCharCode(c);
      }
      lines.add(sb.toString().trimRight());
    }
    return lines.join('\n');
  }

  /// [a] and [b] in reading order.
  static ((int, int), (int, int)) ordered((int, int) a, (int, int) b) =>
      a.$2 < b.$2 || (a.$2 == b.$2 && a.$1 <= b.$1) ? (a, b) : (b, a);

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

/// One scrollback line as the emulator kept it (its own width).
class HistoryRow {
  HistoryRow(this.cp, this.attr);
  final Uint32List cp, attr;
}

/// The emulator's scrollback, as far as the app has fetched it: [total]
/// lines in all (-1 until asked), and a run of them from [start]. The
/// emulator keeps up to 5000 and answers up to 500 a request.
class Scrollback {
  int total = -1;
  int start = 0;
  List<HistoryRow> rows = [];

  /// Asks the emulator for [count] lines from [from] (frame 3); set by a
  /// session that has one. The answer arrives through [take].
  void Function(int from, int count)? request;

  HistoryRow? at(int i) => i >= start && i < start + rows.length ? rows[i - start] : null;

  /// Whether lines [from, from + count) are all here.
  bool has(int from, int count) => from >= start && from + count <= start + rows.length;

  /// A type-6 answer: total (4) | from (4) | count (2) | count x (cols (2)
  /// | cols x (code point (4) | attributes (4))). False when malformed.
  bool take(Uint8List p) {
    if (p.length < 10) return false;
    final b = ByteData.sublistView(p);
    final t = b.getUint32(0), from = b.getUint32(4), count = b.getUint16(8);
    final got = <HistoryRow>[];
    var at = 10;
    for (var i = 0; i < count; i++) {
      if (at + 2 > p.length) return false;
      final w = b.getUint16(at);
      at += 2;
      if (at + w * 8 > p.length) return false;
      final cp = Uint32List(w), attr = Uint32List(w);
      for (var x = 0; x < w; x++) {
        cp[x] = b.getUint32(at + x * 8);
        attr[x] = b.getUint32(at + x * 8 + 4);
      }
      at += w * 8;
      got.add(HistoryRow(cp, attr));
    }
    total = t;
    if (count > 0) {
      start = from;
      rows = got;
    }
    return true;
  }
}
