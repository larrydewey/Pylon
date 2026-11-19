import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../backend/files.dart';
import '../backend/model.dart';
import '../backend/select.dart';
import '../theme.dart';
import 'app_state.dart';
import 'widgets.dart';

/// A host's files over SFTP (SPEC 11): browse, make folders, rename,
/// delete, cut or copy and paste (on the server), download to and upload
/// from this device. Nothing is ever replaced without asking: a paste or a
/// rename refuses a name that is taken (a copy pasted beside its original
/// becomes "NAME copy"), an upload over a file asks first, and a download
/// goes only where the principal chose.
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.st, required this.host});
  final AppState st;
  final Host host;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

// The theme's filled buttons span the width; here they sit in rows.
final _compact = FilledButton.styleFrom(minimumSize: const Size(64, 40));

class _FilesPageState extends State<FilesPage> {
  late FileSession fs;
  Uint8List? cwd, home;
  List<RemoteEntry> entries = [];
  bool loading = true;
  String? error;

  // Selected names (by their bytes as text keys).
  final Set<String> selected = {};

  // A transfer in progress: what, how far, and of how much.
  String? busy;
  int done = 0;
  int? total;

  AppState get st => widget.st;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    fs = st.openFiles(widget.host);
    fs.listen(_onSession);
    setState(() {
      loading = true;
      error = null;
    });
    fs.ready.then(
      (h) {
        home = h;
        _go(h);
      },
      onError: (Object e) {
        if (mounted) setState(() => loading = false);
      },
    );
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    fs.unlisten(_onSession);
    st.closeFiles(fs);
    super.dispose();
  }

  static String _key(List<int> name) => String.fromCharCodes(name);

  Future<void> _go(Uint8List dir) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      // The server's own path: a folder reached through a link is shown
      // (and copied) as what it is.
      final real = await fs.realPath(dir);
      final list = await fs.list(real);
      list.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.shown.toLowerCase().compareTo(b.shown.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        cwd = real;
        entries = list;
        selected.clear();
        loading = false;
      });
    } on FileError catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.message;
      });
    }
  }

  Future<void> _refresh() async {
    final c = cwd;
    if (c != null) await _go(c);
  }

  Uint8List _path(RemoteEntry e) => pathJoin(cwd!, e.name);

  void _say(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text, style: TextStyle(color: bad ? P.red : P.text)),
          backgroundColor: bad ? P.redDeep : P.surface,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: bad ? 6 : 3),
        ),
      );
  }

  /// Runs [f]; a refusal is shown, and the listing refreshed either way.
  Future<void> _act(Future<String?> Function() f) async {
    try {
      final note = await f();
      if (note != null) _say(note);
    } on FileError catch (e) {
      _say(e.message, bad: true);
    } catch (e) {
      _say('$e', bad: true);
    }
    if (mounted) await _refresh();
  }

  List<RemoteEntry> get _picked => [
    for (final e in entries)
      if (selected.contains(_key(e.name))) e,
  ];

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<String?> _ask(String title, String label, {String initial = '', String action = 'OK'}) async {
    final c = TextEditingController(text: initial);
    c.selection = TextSelection(baseOffset: 0, extentOffset: initial.lastIndexOf('.') > 0 ? initial.lastIndexOf('.') : initial.length);
    String? why;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          backgroundColor: P.surface,
          title: Text(title),
          content: TextField(
            controller: c,
            autofocus: true,
            decoration: InputDecoration(labelText: label, errorText: why),
            onSubmitted: (_) {
              final w = badName(c.text);
              if (w != null) return set(() => why = w);
              Navigator.pop(ctx, c.text);
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: _compact,
              onPressed: () {
                final w = badName(c.text);
                if (w != null) return set(() => why = w);
                Navigator.pop(ctx, c.text);
              },
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(String title, String body, String action, {bool danger = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: P.surface,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: danger ? _compact.merge(FilledButton.styleFrom(backgroundColor: P.red, foregroundColor: P.ink)) : _compact,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _newFolder() async {
    final name = await _ask('New folder', 'Name', action: 'Create');
    if (name == null) return;
    await _act(() async {
      await fs.makeDir(pathJoin(cwd!, bytesOf(name)));
      return null;
    });
  }

  Future<void> _rename(RemoteEntry e) async {
    final name = await _ask('Rename', 'New name', initial: e.shown, action: 'Rename');
    if (name == null || sameBytes(bytesOf(name), e.name)) return;
    await _act(() async {
      await fs.move(_path(e), pathJoin(cwd!, bytesOf(name)));
      return null;
    });
  }

  Future<void> _delete(List<RemoteEntry> es) async {
    if (es.isEmpty) return;
    final dirs = es.where((e) => e.isDir).length;
    final what = es.length == 1 ? '"${es.first.shown}"' : '${es.length} items';
    final ok = await _confirm('Delete $what?', dirs > 0 ? 'Folders are deleted with everything in them. This cannot be undone.' : 'This cannot be undone.', 'Delete', danger: true);
    if (!ok) return;
    await _act(() async {
      for (final e in es) {
        await fs.remove(_path(e));
      }
      return es.length == 1 ? 'Deleted ${es.first.shown}' : 'Deleted ${es.length} items';
    });
  }

  void _mark(List<RemoteEntry> es, bool cut) {
    if (es.isEmpty) return;
    st.setClip(FileClip(widget.host, cut, [for (final e in es) _path(e)]));
    // The paste bar says what is marked (a snack bar would cover it).
    setState(selected.clear);
  }

  /// The marked paths moved (cut) or copied into this folder. A copy beside
  /// its original takes a free "NAME copy" name; anything else whose name is
  /// taken here is refused, never replaced.
  Future<void> _paste() async {
    final c = st.clip;
    final here = cwd;
    if (c == null || here == null) return;
    await _act(() async {
      var n = 0;
      final refused = <String>[];
      for (final p in c.paths) {
        final base = baseName(p);
        var to = pathJoin(here, base);
        try {
          if (c.cut) {
            if (sameBytes(p, to)) continue;
            await fs.move(p, to);
          } else {
            if (sameBytes(dirName(p), here)) to = await fs.freeName(here, base);
            await fs.copy(p, to);
          }
          n++;
        } on FileError catch (e) {
          refused.add(e.message);
        }
      }
      if (c.cut) st.setClip(null);
      if (refused.isNotEmpty) throw FileError(refused.join('\n'));
      return n == 0 ? null : '${c.cut ? 'Moved' : 'Copied'} $n ${n == 1 ? 'item' : 'items'}';
    });
  }

  Future<void> _download(RemoteEntry e) async {
    LocalTarget? t;
    try {
      t = systemPicker ? await pickTarget(e.shown) : await _desktopTarget(e.shown);
    } catch (err) {
      _say('$err', bad: true);
      return;
    }
    if (t == null) return;
    final target = t;
    setState(() {
      busy = 'Downloading ${e.shown}';
      done = 0;
      total = e.size;
    });
    var ok = false;
    try {
      final n = await fs.download(_path(e), (chunk) async {
        await target.write(chunk);
        if (mounted) setState(() => done += chunk.length);
      });
      ok = true;
      _say('${sizeText(n)} to ${target.label}');
    } on FileError catch (err) {
      _say(err.message, bad: true);
    } catch (err) {
      _say('Cannot write ${target.label}: $err', bad: true);
    } finally {
      await target.finish(ok).catchError((_) {});
      if (mounted) setState(() => busy = null);
    }
  }

  Future<LocalTarget?> _desktopTarget(String name) async {
    final c = TextEditingController(text: '$downloadsDir/$name');
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: P.surface,
        title: const Text('Download to'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: c,
            autofocus: true,
            style: const TextStyle(fontFamily: mono, fontSize: 13),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: _compact, onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Download')),
        ],
      ),
    );
    if (path == null || path.isEmpty) return null;
    var replace = false;
    if (localExists(path)) {
      replace = await _confirm('Replace $path?', 'A file with that name is already on $deviceName.', 'Replace', danger: true);
      if (!replace) return null;
    }
    return pathTarget(path, replace: replace);
  }

  Future<void> _upload() async {
    final here = cwd;
    if (here == null) return;
    LocalSource? src;
    try {
      src = systemPicker ? await pickSource() : await _desktopSource();
    } catch (err) {
      _say('$err', bad: true);
      return;
    }
    if (src == null) return;
    final source = src;
    final name = bytesOf(source.name.replaceAll('/', '_'));
    var to = pathJoin(here, name);
    var replace = false;
    try {
      final there = await fs.stat(to);
      if (there != null) {
        if (!mounted) return;
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: P.surface,
            title: Text('"${displayName(name)}" is already here'),
            content: Text(there.kind == FileKind.file ? 'Replace the file on the server, or keep both?' : 'Something that is not a file has that name; the upload can be kept beside it.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, 'both'), child: const Text('Keep both')),
              if (there.kind == FileKind.file) FilledButton(style: _compact, onPressed: () => Navigator.pop(ctx, 'replace'), child: const Text('Replace')),
            ],
          ),
        );
        if (choice == null) {
          await source.close();
          return;
        }
        if (choice == 'replace') replace = true;
        if (choice == 'both') to = await fs.freeName(here, name);
      }
    } on FileError catch (e) {
      await source.close();
      _say(e.message, bad: true);
      return;
    }
    setState(() {
      busy = 'Uploading ${source.name}';
      done = 0;
      total = source.size;
    });
    await _act(() async {
      try {
        final n = await fs.upload(to, () async {
          final c = await source.read();
          if (c != null && mounted) setState(() => done += c.length);
          return c;
        }, replace: replace);
        return '${sizeText(n)} to ${displayName(to)}';
      } finally {
        await source.close().catchError((_) {});
        if (mounted) setState(() => busy = null);
      }
    });
  }

  Future<LocalSource?> _desktopSource() async {
    final c = TextEditingController(text: '$downloadsDir/');
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: P.surface,
        title: const Text('Upload a file'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: c,
            autofocus: true,
            style: const TextStyle(fontFamily: mono, fontSize: 13),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(style: _compact, onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Upload')),
        ],
      ),
    );
    if (path == null || path.isEmpty) return null;
    return pathSource(path);
  }

  void _open(RemoteEntry e) {
    if (selected.isNotEmpty) return _toggle(e);
    // A link: followed only to browse into it (never by a copy or delete).
    if (e.isDir || e.kind == FileKind.link) {
      _go(_path(e));
      return;
    }
    _sheet(e);
  }

  void _toggle(RemoteEntry e) {
    setState(() {
      final k = _key(e.name);
      if (!selected.remove(k)) selected.add(k);
    });
  }

  void _sheet(RemoteEntry e) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: P.surface,
      builder: (ctx) {
        Widget item(IconData i, String t, VoidCallback f, {Color? color}) => ListTile(
          leading: Icon(i, color: color ?? P.muted),
          title: Text(t, style: TextStyle(color: color)),
          onTap: () {
            Navigator.pop(ctx);
            f();
          },
        );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(e.shown, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(_detail(e), style: const TextStyle(color: P.muted)),
                ),
                if (e.kind == FileKind.file) item(Icons.download, 'Download to $deviceName', () => _download(e)),
                item(Icons.drive_file_rename_outline, 'Rename', () => _rename(e)),
                item(Icons.content_cut, 'Cut', () => _mark([e], true)),
                item(Icons.content_copy, 'Copy', () => _mark([e], false)),
                item(Icons.delete_outline, 'Delete', () => _delete([e]), color: P.red),
              ],
            ),
          ),
        );
      },
    );
  }

  String _detail(RemoteEntry e) {
    final what = switch (e.kind) {
      FileKind.dir => 'Folder',
      FileKind.link => 'Link',
      FileKind.file => sizeText(e.size),
      _ => 'Special file',
    };
    final when = whenText(e.mtime);
    return when.isEmpty ? what : '$what · $when';
  }

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    final clip = st.clip;
    final canPaste = clip != null && identical(clip.host, widget.host) && cwd != null;
    final atTop = cwd == null || (cwd!.length == 1 && cwd![0] == 0x2f);
    return PopScope(
      canPop: selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(selected.clear);
      },
      child: Scaffold(
        appBar: AppBar(
          title: selected.isNotEmpty
              ? Text('${selected.length} selected')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.host.name),
                    if (cwd != null)
                      Text(
                        displayName(cwd!),
                        style: const TextStyle(fontFamily: mono, fontSize: 12, color: P.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
          actions: selected.isNotEmpty
              ? [
                  IconButton(tooltip: 'Cut', icon: const Icon(Icons.content_cut), onPressed: () => _mark(picked, true)),
                  IconButton(tooltip: 'Copy', icon: const Icon(Icons.content_copy), onPressed: () => _mark(picked, false)),
                  if (picked.length == 1) IconButton(tooltip: 'Rename', icon: const Icon(Icons.drive_file_rename_outline), onPressed: () => _rename(picked.first)),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline, color: P.red),
                    onPressed: () => _delete(picked),
                  ),
                  IconButton(tooltip: 'Clear selection', icon: const Icon(Icons.close), onPressed: () => setState(selected.clear)),
                ]
              : [
                  IconButton(tooltip: 'Up', icon: const Icon(Icons.arrow_upward), onPressed: atTop || busy != null ? null : () => _go(dirName(cwd!))),
                  IconButton(tooltip: 'Home', icon: const Icon(Icons.home_outlined), onPressed: home == null || busy != null ? null : () => _go(home!)),
                  IconButton(tooltip: 'New folder', icon: const Icon(Icons.create_new_folder_outlined), onPressed: cwd == null || busy != null ? null : _newFolder),
                  IconButton(tooltip: 'Upload', icon: const Icon(Icons.upload), onPressed: cwd == null || busy != null ? null : _upload),
                  IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: cwd == null || busy != null ? null : _refresh),
                ],
        ),
        body: Column(
          children: [
            if (busy != null) _progress(),
            if (st.backend.demo)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Chip2('Demo: no server behind these files', fg: P.amber, bg: Color(0xFF3A2C10)),
              ),
            Expanded(child: _body()),
          ],
        ),
        // In the bottom bar, floating snack bars stay above it.
        bottomNavigationBar: canPaste ? _pasteBar(clip) : null,
      ),
    );
  }

  Widget _progress() => Container(
    color: P.surface,
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$busy · ${sizeText(done)}${total != null ? ' of ${sizeText(total!)}' : ''}', style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: total != null && total! > 0 ? (done / total!).clamp(0.0, 1.0) : null, color: P.teal, backgroundColor: P.line),
      ],
    ),
  );

  Widget _pasteBar(FileClip clip) => Container(
    decoration: const BoxDecoration(
      color: P.surface,
      border: Border(top: BorderSide(color: P.line)),
    ),
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          Icon(clip.cut ? Icons.content_cut : Icons.content_copy, size: 18, color: P.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${clip.paths.length == 1 ? displayName(baseName(clip.paths.first)) : '${clip.paths.length} items'} ${clip.cut ? 'to move' : 'to copy'}', overflow: TextOverflow.ellipsis),
          ),
          TextButton(onPressed: () => st.setClip(null), child: const Text('Clear')),
          FilledButton(style: _compact, onPressed: busy != null ? null : _paste, child: Text(clip.cut ? 'Move here' : 'Paste here')),
        ],
      ),
    ),
  );

  Widget _body() {
    if (fs.ended && cwd == null) {
      return _message(fs.status.isEmpty ? 'The connection closed.' : fs.status, retry: true);
    }
    if (cwd == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: P.teal),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                visible(fs.status.isEmpty ? 'Connecting…' : fs.status),
                textAlign: TextAlign.center,
                style: const TextStyle(color: P.muted),
              ),
            ),
          ],
        ),
      );
    }
    if (fs.ended) return _message(fs.status, retry: true);
    if (error != null) return _message(error!, retry: false);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: entries.isEmpty ? 1 : entries.length,
        itemBuilder: (ctx, i) {
          if (entries.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                loading ? '' : 'This folder is empty.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: P.muted),
              ),
            );
          }
          final e = entries[i];
          final on = selected.contains(_key(e.name));
          return ListTile(
            selected: on,
            selectedTileColor: P.tealDeep,
            leading: Icon(
              on
                  ? Icons.check_circle
                  : switch (e.kind) {
                      FileKind.dir => Icons.folder,
                      FileKind.link => Icons.link,
                      FileKind.file => Icons.insert_drive_file_outlined,
                      _ => Icons.help_outline,
                    },
              color: on ? P.teal : (e.isDir ? P.tealText : P.muted),
            ),
            title: Text(e.shown, overflow: TextOverflow.ellipsis),
            subtitle: Text(_detail(e), style: const TextStyle(fontSize: 12, color: P.muted)),
            trailing: selected.isEmpty
                ? IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert, color: P.muted),
                    onPressed: () => _sheet(e),
                  )
                : null,
            onTap: () => _open(e),
            onLongPress: () => _toggle(e),
          );
        },
      ),
    );
  }

  Widget _message(String text, {required bool retry}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            visible(text),
            textAlign: TextAlign.center,
            style: const TextStyle(color: P.red),
          ),
          const SizedBox(height: 16),
          if (retry)
            FilledButton(
              style: _compact,
              onPressed: () {
                fs.unlisten(_onSession);
                st.closeFiles(fs);
                setState(() => cwd = null);
                _connect();
              },
              child: const Text('Reconnect'),
            )
          else
            TextButton(onPressed: home == null ? null : () => _go(home!), child: const Text('Go home')),
        ],
      ),
    ),
  );
}
