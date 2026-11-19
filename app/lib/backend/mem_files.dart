import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'files.dart';

/// A file tree in memory, with the core's rules (nothing replaced, links
/// never followed, no directory into itself): the demo's Files page, and
/// the tests'.
class MemFiles extends FileSession {
  MemFiles(super.host, {Map<String, Uint8List?>? tree}) {
    // A path ending in / is a directory; a null value too.
    final t = tree ??
        {
          '/home/demo/notes.txt': bytesOf('Demo mode: no server behind these files.\n'),
          '/home/demo/src/': null,
          '/home/demo/src/main.c': bytesOf('int main(void) { return 0; }\n'),
          '/home/demo/photos/': null,
        };
    _dirs.add('/');
    for (final e in t.entries) {
      final p = e.key.endsWith('/') ? e.key.substring(0, e.key.length - 1) : e.key;
      _parents(p);
      if (e.value == null || e.key.endsWith('/')) {
        _dirs.add(p);
      } else {
        _files[p] = e.value!;
      }
    }
  }

  final Set<String> _dirs = {};
  final Map<String, Uint8List> _files = {};

  /// Symbolic links: path to target (never followed here).
  final Map<String, String> links = {};
  int _clock = 1763550000;

  void _parents(String p) {
    var d = p;
    while (true) {
      final k = d.lastIndexOf('/');
      if (k <= 0) break;
      d = d.substring(0, k);
      _dirs.add(d);
    }
  }

  String _s(Uint8List p) {
    final s = utf8.decode(p, allowMalformed: true);
    return s.length > 1 && s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  bool _exists(String p) => _dirs.contains(p) || _files.containsKey(p) || links.containsKey(p);

  Iterable<String> _under(String d) sync* {
    final pre = d == '/' ? '/' : '$d/';
    for (final p in [..._dirs, ..._files.keys, ...links.keys]) {
      if (p != d && p.startsWith(pre)) yield p;
    }
  }

  RemoteEntry _entry(String p) {
    final name = bytesOf(p.substring(p.lastIndexOf('/') + 1));
    if (links.containsKey(p)) return RemoteEntry(name, FileKind.link, links[p]!.length, 0xA1FF, _clock);
    if (_dirs.contains(p)) return RemoteEntry(name, FileKind.dir, 4096, 0x41ED, _clock);
    return RemoteEntry(name, FileKind.file, _files[p]!.length, 0x81A4, _clock);
  }

  @override
  Future<Uint8List> get ready async => bytesOf('/home/demo');

  @override
  Future<List<RemoteEntry>> list(Uint8List dir) async {
    final d = _s(dir);
    if (!_dirs.contains(d)) throw FileError('cannot list $d: No such file');
    final pre = d == '/' ? '/' : '$d/';
    return [
      for (final p in {..._dirs, ..._files.keys, ...links.keys})
        if (p != d && p.startsWith(pre) && !p.substring(pre.length).contains('/')) _entry(p)
    ];
  }

  @override
  Future<Uint8List> realPath(Uint8List path) async => bytesOf(_s(path));

  @override
  Future<void> makeDir(Uint8List path) async {
    final p = _s(path);
    if (_exists(p)) throw FileError('cannot make the directory $p: Failure');
    if (!_dirs.contains(_s(dirName(path)))) throw FileError('cannot make the directory $p: No such file');
    _dirs.add(p);
  }

  @override
  Future<TreeDone> remove(Uint8List path) async {
    final p = _s(path);
    if (!_exists(p)) throw FileError('no such file $p');
    var files = 0, dirs = 0;
    for (final q in [..._under(p).toList()..sort((a, b) => b.length.compareTo(a.length)), p]) {
      if (_dirs.remove(q)) {
        dirs++;
      } else if (_files.remove(q) != null || links.remove(q) != null) {
        files++;
      }
    }
    return TreeDone(files, dirs, 0);
  }

  @override
  Future<void> move(Uint8List from, Uint8List to) async {
    final f = _s(from), t = _s(to);
    if (!_exists(f)) throw FileError('no such file $f');
    if (_exists(t)) throw FileError('$t already exists; not replaced');
    if (t.startsWith('$f/')) throw FileError('cannot move $f: Failure');
    String moved(String q) => t + q.substring(f.length);
    for (final q in [f, ..._under(f)]) {
      if (_dirs.remove(q)) _dirs.add(moved(q));
      final data = _files.remove(q);
      if (data != null) _files[moved(q)] = data;
      final l = links.remove(q);
      if (l != null) links[moved(q)] = l;
    }
  }

  @override
  Future<TreeDone> copy(Uint8List from, Uint8List to) async {
    final f = _s(from), t = _s(to);
    if (!_exists(f)) throw FileError('no such file $f');
    if (links.containsKey(f)) throw FileError('$f is a symbolic link; not copied');
    if (t == f || t.startsWith('$f/')) throw FileError('cannot copy $f into itself');
    if (_exists(t)) throw FileError('$t already exists; not replaced');
    var files = 0, dirs = 0, skipped = 0;
    for (final q in [f, ..._under(f)]) {
      final n = t + q.substring(f.length);
      if (_dirs.contains(q)) {
        _dirs.add(n);
        dirs++;
      } else if (_files.containsKey(q)) {
        _files[n] = Uint8List.fromList(_files[q]!);
        files++;
      } else {
        skipped++;
      }
    }
    return TreeDone(files, dirs, skipped);
  }

  @override
  Future<RemoteEntry?> stat(Uint8List path) async {
    final p = _s(path);
    return _exists(p) ? _entry(p) : null;
  }

  @override
  Future<Uint8List> freeName(Uint8List dir, Uint8List name) async {
    final n = utf8.decode(name, allowMalformed: true);
    final dot = n.lastIndexOf('.');
    final at = dot > 0 ? dot : n.length;
    for (var i = 0; i < 100; i++) {
      final c = '${n.substring(0, at)} copy${i == 0 ? '' : ' ${i + 1}'}${n.substring(at)}';
      final p = pathJoin(dir, bytesOf(c));
      if (!_exists(_s(p))) return p;
    }
    throw FileError('no free name for a copy of $n');
  }

  @override
  Future<int> download(Uint8List path, Future<void> Function(Uint8List chunk) sink) async {
    final p = _s(path);
    final d = _files[p];
    if (d == null) throw FileError(_dirs.contains(p) ? '$p is a directory' : 'cannot open $p on the server: No such file');
    for (var i = 0; i < d.length; i += 32768) {
      await sink(Uint8List.sublistView(d, i, i + 32768 < d.length ? i + 32768 : d.length));
    }
    return d.length;
  }

  @override
  Future<int> upload(Uint8List path, Future<Uint8List?> Function() source, {bool replace = false}) async {
    final p = _s(path);
    final b = BytesBuilder();
    while (true) {
      final c = await source();
      if (c == null || c.isEmpty) break;
      b.add(c);
    }
    if (_exists(p) && (!replace || !_files.containsKey(p))) throw FileError('$p already exists; not replaced');
    _files[p] = b.toBytes();
    _clock++;
    return _files[p]!.length;
  }

  /// A file's bytes, for tests.
  Uint8List? fileAt(String p) => _files[p];
  bool dirAt(String p) => _dirs.contains(p);

  @override
  void close() {
    ended = true;
  }
}
