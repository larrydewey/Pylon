// Out-of-band host key values (SPEC 6.1.4), as the app reads them from a
// scanned QR code or a paste: the same rules as the CLI's core/oob.resid.
//
//   SHA256:BASE64                          a bare fingerprint
//   256 SHA256:BASE64 root@h (ED25519)     lines of `ssh-keygen -lf`
//   pylon-hostkey/1 HOST[:PORT] SHA256:... the QR payload, bound to a host
//                                          (an IPv6 HOST with a port in
//                                          brackets: [ADDR]:PORT)
//
// The app compares the result with the key the host presents (through
// `pylon pin`); nothing here trusts a key by itself.

import 'dart:convert';
import 'dart:io';

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

/// An IPv6 address in its RFC 5952 form (as the CLI writes it).
String _canonical6(InternetAddress a) => InternetAddress.fromRawAddress(a.rawAddress).address;

/// A payload's HOST[:PORT]: the host (an IPv6 one canonical, any other in
/// lower case; null when malformed) and the port text (null when none).
(String?, String?) _splitHost(String spec) {
  String? v6(String s) {
    final a = InternetAddress.tryParse(s);
    return a != null && a.type == InternetAddressType.IPv6 ? _canonical6(a) : null;
  }

  if (spec.startsWith('[')) {
    final close = spec.indexOf(']');
    final h = close > 0 ? v6(spec.substring(1, close)) : null;
    final rest = close > 0 ? spec.substring(close + 1) : '';
    if (h == null || (rest.isNotEmpty && !rest.startsWith(':'))) return (null, null);
    return (h, rest.isEmpty ? null : rest.substring(1));
  }
  final bare = v6(spec);
  if (bare != null) return (bare, null);
  final hp = spec.split(':');
  final host = hp[0].toLowerCase();
  if (hp.length > 2 || !_host.hasMatch(host)) return (null, null);
  return (host, hp.length == 2 ? hp[1] : null);
}

HostKeyValue _payload(List<String> ws) {
  if (ws.length < 3) throw const HostKeyValueError('the payload names no host or no fingerprint');
  if (ws.length > 2 + maxFingerprints) throw const HostKeyValueError('more than $maxFingerprints fingerprints');
  final hr = _splitHost(ws[1]);
  final host = hr.$1;
  final ps = hr.$2;
  int? port;
  if (ps != null && RegExp(r'^[0-9]{1,5}$').hasMatch(ps)) port = int.parse(ps);
  final portOk = ps == null || (port != null && port >= 1 && port <= 65535);
  if (host == null || !portOk) throw const HostKeyValueError("the payload's host is not HOST, HOST:PORT or [IPV6]:PORT");
  final fps = <String>[];
  for (final w in ws.skip(2)) {
    final n = normalizeFingerprint(w);
    if (n == null) throw const HostKeyValueError('the payload holds something other than SHA256: fingerprints');
    if (!fps.contains(n)) fps.add(n);
  }
  return HostKeyValue(host, port, fps);
}

/// The payload a host shows as a QR code for the principal to scan.
String hostKeyPayload(String host, int port, List<String> fingerprints) {
  final a = InternetAddress.tryParse(host);
  final v6 = a != null && a.type == InternetAddressType.IPv6;
  final h = v6 ? _canonical6(a) : host.toLowerCase();
  final shown = port != 22;
  return '$payloadTag ${v6 && shown ? '[$h]' : h}${shown ? ':$port' : ''} ${fingerprints.join(' ')}';
}
