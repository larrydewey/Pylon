import 'dart:convert';
import 'dart:typed_data';

import 'model.dart';

/// What a remote path is: as the core reports it (kind byte).
enum FileKind { file, dir, link, other, unknown }

FileKind kindOf(int b) => switch (b) {
      0 => FileKind.file,
      1 => FileKind.dir,
      2 => FileKind.link,
      3 => FileKind.other,
      _ => FileKind.unknown,
    };

/// One name in a remote directory: its bytes exactly as the server spelled
/// them (sent back unchanged in requests), and its attributes.
class RemoteEntry {
  RemoteEntry(this.name, this.kind, this.size, this.perms, this.mtime);
  final Uint8List name;
  final FileKind kind;
  final int size, perms, mtime;
  String get shown => displayName(name);
  bool get isDir => kind == FileKind.dir;
}

/// A request the core (or the server) refused, with its reason (already
/// escaped by the core).
class FileError implements Exception {
  FileError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What copying or removing a tree did.
class TreeDone {
  TreeDone(this.files, this.dirs, this.skipped);
  final int files, dirs, skipped;
}

/// A file browser's connection to one host (`pylon sftp --app`, SPEC 11):
/// requests are answered one at a time, in order. Nothing the server says
/// chooses where a file lands on this device; nothing is replaced unless
/// asked ([upload] with replace), and moves and copies refuse a
/// destination that exists.
abstract class FileSession {
  FileSession(this.host);
  final Host host;

  /// The starting directory (the login directory), when connected.
  Future<Uint8List> get ready;

  /// Text from the core for the principal while connecting (prompts,
  /// refusals); the reason when the session ended.
  String status = '';

  /// Set when the session ended (the connection failed or closed).
  bool ended = false;

  Future<List<RemoteEntry>> list(Uint8List dir);
  Future<Uint8List> realPath(Uint8List path);
  Future<void> makeDir(Uint8List path);

  /// A file, a link (never what it names) or a directory with its contents.
  Future<TreeDone> remove(Uint8List path);

  /// Moves or renames; `to` is the new path, which must not exist.
  Future<void> move(Uint8List from, Uint8List to);

  /// Copies a file, or a directory with its contents (symbolic links are
  /// skipped, never followed); `to` must not exist.
  Future<TreeDone> copy(Uint8List from, Uint8List to);

  /// lstat: null when nothing is there.
  Future<RemoteEntry?> stat(Uint8List path);

  /// A free "NAME copy" (then "NAME copy 2", ...) path in dir.
  Future<Uint8List> freeName(Uint8List dir, Uint8List name);

  /// The file's bytes, chunk by chunk, to [sink]; the total.
  Future<int> download(Uint8List path, Future<void> Function(Uint8List chunk) sink);

  /// The bytes from [source] (null: the end) into path; without [replace]
  /// a path that exists is refused. The total.
  Future<int> upload(Uint8List path, Future<Uint8List?> Function() source, {bool replace = false});

  void close();

  final List<void Function()> _listeners = [];
  void listen(void Function() f) => _listeners.add(f);
  void unlisten(void Function() f) => _listeners.remove(f);
  void changed() {
    for (final f in List.of(_listeners)) {
      f();
    }
  }
}

// ---------------------------------------------------------------------------
// Names and paths (bytes)
// ---------------------------------------------------------------------------

/// A remote name for display (SPEC 11): UTF-8 when it is valid, else each
/// byte past ASCII as \xHH; control characters, bidi controls and
/// characters that look like a slash are shown as escapes, so a name can
/// neither drive the display nor pass for a path.
String displayName(List<int> b) {
  String text;
  try {
    text = utf8.decode(b);
  } on FormatException {
    final s = StringBuffer();
    for (final c in b) {
      if (c < 0x80) {
        s.writeCharCode(c);
      } else {
        s.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
      }
    }
    text = s.toString();
  }
  final out = StringBuffer();
  for (final r in text.runes) {
    final bidi = (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) || r == 0x200E || r == 0x200F || r == 0x061C;
    final slashy = r == 0x2215 || r == 0x2044 || r == 0xFF0F || r == 0x29F8 || r == 0x2571 || r == 0x1735;
    final control = r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0);
    if (control && r < 0x100) {
      out.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
    } else if (bidi || slashy || control) {
      out.write('\\u{${r.toRadixString(16)}}');
    } else {
      out.writeCharCode(r);
    }
  }
  return out.toString();
}

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _trimmed(List<int> p) {
  var n = p.length;
  while (n > 1 && p[n - 1] == 0x2f) {
    n--;
  }
  return Uint8List.fromList(p.sublist(0, n));
}

/// A name inside a directory.
Uint8List pathJoin(List<int> dir, List<int> name) {
  if (name.isNotEmpty && name[0] == 0x2f) return Uint8List.fromList(name);
  if (dir.isEmpty) return Uint8List.fromList(name);
  return Uint8List.fromList([...dir, if (dir.last != 0x2f) 0x2f, ...name]);
}

Uint8List baseName(List<int> p0) {
  final p = _trimmed(p0);
  final k = p.lastIndexOf(0x2f);
  return Uint8List.fromList(p.sublist(k + 1));
}

Uint8List dirName(List<int> p0) {
  final p = _trimmed(p0);
  final k = p.lastIndexOf(0x2f);
  if (k < 0) return Uint8List.fromList([0x2e]);
  if (k == 0) return Uint8List.fromList([0x2f]);
  return Uint8List.fromList(p.sublist(0, k));
}

/// A name the principal typed, or the reason it cannot be one.
String? badName(String name) {
  if (name.isEmpty) return 'Give a name.';
  if (name == '.' || name == '..') return 'That name is taken by the directory itself.';
  if (name.contains('/')) return 'A name cannot hold a slash.';
  if (name.runes.any((r) => r < 0x20 || r == 0x7f)) return 'A name cannot hold control characters.';
  return null;
}

/// "4.2 MB" and so on.
String sizeText(int n) {
  if (n < 1000) return '$n B';
  const units = ['kB', 'MB', 'GB', 'TB'];
  var v = n / 1000;
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

String whenText(int t) {
  if (t <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(t * 1000);
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

// ---------------------------------------------------------------------------
// The framed protocol (cli/sftp_shell.resid), shared by the real session
// and the tests
// ---------------------------------------------------------------------------

Uint8List request(int op, List<List<int>> args) {
  final b = BytesBuilder(copy: false)..addByte(op);
  for (final a in args) {
    b.add([(a.length >> 24) & 255, (a.length >> 16) & 255, (a.length >> 8) & 255, a.length & 255]);
    b.add(a);
  }
  return b.toBytes();
}

int _u32(List<int> b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
int _u64(List<int> b, int at) => (_u32(b, at) << 32) | _u32(b, at + 4);

RemoteEntry _entryAt(Uint8List name, List<int> b, int at) => RemoteEntry(name, kindOf(b[at]), _u64(b, at + 1), _u32(b, at + 9), _u32(b, at + 13));

/// A LIST result: count, then per entry name | kind | size | perms | mtime.
List<RemoteEntry> parseList(Uint8List b) {
  final n = _u32(b, 0);
  final out = <RemoteEntry>[];
  var at = 4;
  for (var i = 0; i < n; i++) {
    final len = _u32(b, at);
    final name = Uint8List.sublistView(b, at + 4, at + 4 + len);
    out.add(_entryAt(Uint8List.fromList(name), b, at + 4 + len));
    at += 4 + len + 17;
  }
  return out;
}

RemoteEntry? parseStat(Uint8List path, Uint8List b) => b[0] == 0 ? null : _entryAt(baseName(path), b, 1);

TreeDone parseDone(Uint8List b) => TreeDone(_u32(b, 0), _u32(b, 4), _u32(b, 8));

int parseCount(Uint8List b) => _u64(b, 0);
