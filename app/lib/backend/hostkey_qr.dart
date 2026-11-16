// Out-of-band host key values (SPEC 6.1.4), as the app reads them from a
// scanned QR code or a paste: the same rules as the CLI's core/oob.resid.
//
//   SHA256:BASE64                          a bare fingerprint
//   256 SHA256:BASE64 root@h (ED25519)     lines of `ssh-keygen -lf`
//   pylon-hostkey/1 HOST[:PORT] SHA256:... the QR payload, bound to a host
//
// The app compares the result with the key the host presents (through
// `pylon pin`); nothing here trusts a key by itself.

import 'dart:convert';

class HostKeyValue {
  /// The host the payload names, or null for a bare value or lines.
  final String? host;

  /// The payload's port, or null when it names none (22 is assumed).
  final int? port;

  /// Fingerprints as `ssh-keygen -l` prints them (SHA256:..., no padding).
  final List<String> fingerprints;

  const HostKeyValue(this.host, this.port, this.fingerprints);
}

class HostKeyValueError implements Exception {
  final String message;
  const HostKeyValueError(this.message);
  @override
  String toString() => message;
}

const String payloadTag = 'pylon-hostkey/1';
const int maxFingerprints = 8;

final RegExp _b64 = RegExp(r'^[A-Za-z0-9+/]{43}$');
final RegExp _host = RegExp(r'^[a-z0-9._-]{1,253}$');

/// The normalized fingerprint, or null when [w] is not one.
String? normalizeFingerprint(String w) {
  if (!w.startsWith('SHA256:')) return null;
  var b = w.substring(7);
  if (b.length == 44 && b.endsWith('=')) b = b.substring(0, 43);
  if (!_b64.hasMatch(b)) return null;
  final List<int> d;
  try {
    d = base64.decode('$b=');
  } on FormatException {
    return null;
  }
  if (d.length != 32) return null;
  final n = base64.encode(d).replaceAll('=', '');
  return n == b ? 'SHA256:$n' : null;
}

/// Parses pasted or scanned text; throws [HostKeyValueError] when it is
/// not usable.
HostKeyValue parseHostKeyValue(String text) {
  final ws = text.split(RegExp(r'[ \t\r\n]+')).where((w) => w.isNotEmpty).toList();
  if (ws.isEmpty) throw const HostKeyValueError('no fingerprint given');
  if (ws[0] == payloadTag) return _payload(ws);
  if (ws[0].startsWith('pylon-hostkey/')) {
    throw HostKeyValueError('an unknown payload version (${ws[0]}); this app reads $payloadTag');
  }
  final fps = <String>[];
  for (final w in ws) {
    if (w.startsWith('MD5:')) {
      throw const HostKeyValueError('MD5 fingerprints are not accepted; use ssh-keygen -lf (SHA256, its default)');
    }
    if (!w.startsWith('SHA256:')) continue;
    final n = normalizeFingerprint(w);
    if (n == null) throw HostKeyValueError('a malformed fingerprint: $w');
    if (fps.contains(n)) continue;
    if (fps.length >= maxFingerprints) throw const HostKeyValueError('more than $maxFingerprints fingerprints');
    fps.add(n);
  }
  if (fps.isEmpty) throw const HostKeyValueError('no SHA256: fingerprint found (give it as ssh-keygen -lf prints it)');
  return HostKeyValue(null, null, fps);
}

HostKeyValue _payload(List<String> ws) {
  if (ws.length < 3) throw const HostKeyValueError('the payload names no host or no fingerprint');
  if (ws.length > 2 + maxFingerprints) throw const HostKeyValueError('more than $maxFingerprints fingerprints');
  final hp = ws[1].split(':');
  final host = hp[0].toLowerCase();
  int? port;
  if (hp.length == 2 && RegExp(r'^[0-9]{1,5}$').hasMatch(hp[1])) port = int.parse(hp[1]);
  final portOk = hp.length == 1 || (port != null && port >= 1 && port <= 65535);
  if (!_host.hasMatch(host) || !portOk) throw const HostKeyValueError("the payload's host is not HOST or HOST:PORT");
  final fps = <String>[];
  for (final w in ws.skip(2)) {
    final n = normalizeFingerprint(w);
    if (n == null) throw const HostKeyValueError('the payload holds something other than SHA256: fingerprints');
    if (!fps.contains(n)) fps.add(n);
  }
  return HostKeyValue(host, port, fps);
}

/// The payload a host shows as a QR code for the principal to scan.
String hostKeyPayload(String host, int port, List<String> fingerprints) =>
    '$payloadTag ${host.toLowerCase()}${port != 22 ? ':$port' : ''} ${fingerprints.join(' ')}';
