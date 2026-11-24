// Getting a key into a host: what the core says when a host refused every
// key the agent offered, public key lines as the principal pastes them,
// and what `pylon authorize` reports. Text only; nothing here connects.

import 'dart:convert';

/// In the core's message when the host refused every key it was offered.
const refusedMarker = "accepted none of the agent's keys";

/// A key the core lists under "Offered:": two spaces, then exactly an
/// authorized_keys line.
final RegExp offeredKeyLine = RegExp(r'^  ((?:ssh|ecdsa|sk|rsa)-\S+) ([A-Za-z0-9+/]+={0,2})( \S+)?$');

/// A public key line: TYPE BASE64 [COMMENT], the comment one word.
final RegExp keyLinePattern = RegExp(r'^((?:ssh|ecdsa|sk|rsa)-\S+) ([A-Za-z0-9+/]+={0,2})( \S+)?$');

/// What the core said when a host accepted none of the agent's keys.
class KeyRefusal {
  KeyRefusal({required this.target, required this.keys, required this.certificates, required this.commands, required this.fix, required this.notes, required this.raw});

  /// USER@HOST as the core named it ('' when it named none).
  final String target;

  /// The keys offered, each an authorized_keys line to copy.
  final List<String> keys;

  /// How many certificates were offered too (not keys to copy).
  final int certificates;

  /// The ready `pylon authorize ...` commands.
  final List<String> commands;

  /// The line that fixes the modes sshd insists on, or null.
  final String? fix;

  /// The core's own lines on what the server accepts, or why it may
  /// refuse.
  final List<String> notes;

  /// The whole message, as the core wrote it.
  final String raw;
}

/// The refusal in [text] (a session's or a run's messages from the core),
/// or null when it holds none.
KeyRefusal? parseKeyRefusal(String text) {
  final lines = text.split('\n');
  final i = lines.indexWhere((l) => l.contains(refusedMarker));
  if (i < 0) return null;
  final t = RegExp(r'(\S+@\S+) ' + RegExp.escape(refusedMarker)).firstMatch(lines[i]);
  final keys = <String>[], commands = <String>[], notes = <String>[];
  var certs = 0;
  String? fix;
  var howTo = false; // past "To let a key in": the core's own instructions
  for (final raw in lines.skip(i + 1)) {
    final l = raw.trimRight();
    final k = offeredKeyLine.firstMatch(l);
    if (k != null) {
      if (!keys.contains(l.trim())) keys.add(l.trim());
    } else if (l.startsWith('  certificate ')) {
      certs++;
    } else if (l.startsWith('  pylon authorize ')) {
      commands.add(l.trim());
    } else if (l.trimLeft().startsWith('chmod ')) {
      fix = l.trim();
    } else if (l.startsWith('To let a key in') || l.startsWith('Or append')) {
      howTo = true;
    } else if (l.trim().isNotEmpty && l.trim() != 'Offered:' && !howTo) {
      notes.add(l.trim());
    }
  }
  return KeyRefusal(target: t?.group(1) ?? '', keys: keys, certificates: certs, commands: commands, fix: fix, notes: notes, raw: text.trim());
}

/// The command that installs [keys] on [target] from a device that can
/// already log in to it, when the core gave none. Key lines hold no
/// single quote ([keyLinePattern]), so quoting them is safe.
String authorizeCommand(String target, int port, String jump, List<String> keys) =>
    ['pylon authorize', if (port != 22) '-p $port', if (jump.isNotEmpty) '-J $jump', target, for (final k in keys) "'$k'"].join(' ');

/// The line that makes sshd read ~/.ssh/authorized_keys (it ignores one
/// others could write).
const modesFix = 'chmod go-w ~ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys';

/// Why [line] is not a public key line, or null when it is one. It must
/// be TYPE BASE64 [COMMENT] with a one-word comment, and the key inside
/// must be of the type the line names.
String? keyLineProblem(String line) {
  final ws = line.split(RegExp(r'\s+'));
  if (ws.isNotEmpty && !RegExp(r'^(?:ssh|ecdsa|sk|rsa)-').hasMatch(ws[0])) {
    final at = ws.indexWhere((w) => RegExp(r'^(?:ssh|ecdsa|sk|rsa)-').hasMatch(w));
    return at > 0 ? 'options before the key type are not accepted; start the line at ${ws[at]}' : 'not a public key line (TYPE BASE64 COMMENT, e.g. ssh-ed25519 AAAA… name)';
  }
  if (ws.length > 3) return 'the comment must be one word (no spaces), or left out';
  final m = keyLinePattern.firstMatch(ws.join(' '));
  if (m == null) return 'not a public key line (TYPE BASE64 COMMENT, e.g. ssh-ed25519 AAAA… name)';
  final alg = m.group(1)!;
  if (alg.contains('-cert-')) return 'a certificate, not a key';
  final List<int> blob;
  try {
    blob = base64.decode(m.group(2)!);
  } on FormatException {
    return 'the key is not valid base64 (cut short when copied?)';
  }
  // Every public key blob is a run of length-prefixed strings, the first
  // its type, that ends exactly at the end.
  final parts = <List<int>>[];
  for (var at = 0; at < blob.length;) {
    if (blob.length - at < 4) return 'the key is cut short';
    final n = (blob[at] << 24) | (blob[at + 1] << 16) | (blob[at + 2] << 8) | blob[at + 3];
    if (n > blob.length - at - 4) return 'the key is cut short';
    parts.add(blob.sublist(at + 4, at + 4 + n));
    at += 4 + n;
  }
  if (parts.length < 2 || utf8.decode(parts[0], allowMalformed: true) != alg) {
    return 'the key inside is not a $alg key (cut short or mixed up when copied?)';
  }
  if (alg == 'ssh-ed25519' && (parts.length != 2 || parts[1].length != 32)) return 'the key is cut short';
  return null;
}

/// Pasted text as key lines: one per line, blank lines and # comments
/// skipped, runs of spaces made one, the same key once. [problems] says
/// what is wrong with the others, by line number.
({List<String> keys, List<String> problems}) parseKeyLines(String text) {
  final keys = <String>[], problems = <String>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i].trim();
    if (l.isEmpty || l.startsWith('#')) continue;
    final why = keyLineProblem(l);
    if (why != null) {
      problems.add('Line ${i + 1}: $why.');
      continue;
    }
    final k = l.split(RegExp(r'\s+')).join(' ');
    final key = k.split(' ').take(2).join(' ');
    if (!keys.any((o) => o.split(' ').take(2).join(' ') == key)) keys.add(k);
  }
  return (keys: keys, problems: problems);
}

enum ReportKind { added, present, fixed, warning, done, other }

/// One line of what `pylon authorize` did.
class ReportLine {
  const ReportLine(this.kind, this.text);
  final ReportKind kind;

  /// The line without its first word (for [ReportKind.other], all of it).
  final String text;
}

ReportLine parseReportLine(String line) {
  final l = line.trim();
  final sp = l.indexOf(' ');
  final word = sp < 0 ? l : l.substring(0, sp);
  final rest = sp < 0 ? '' : l.substring(sp + 1).trim();
  return switch (word) {
    'added' => ReportLine(ReportKind.added, rest),
    'present' => ReportLine(ReportKind.present, rest),
    'fixed' => ReportLine(ReportKind.fixed, rest),
    'warning' => ReportLine(ReportKind.warning, rest),
    'done' when rest.isEmpty => const ReportLine(ReportKind.done, ''),
    _ => ReportLine(ReportKind.other, l),
  };
}
