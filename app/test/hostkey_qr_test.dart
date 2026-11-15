import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/hostkey_qr.dart';

const fp1 = 'SHA256:MIZwCEPC1dHnGiEluHzU2d3d+fxDOWvqq76It20c4Wk';
const fp2 = 'SHA256:Zb1PvtoHrMXhVVg3TQ9SnT6sHstm+3KIUV549RqzP4Y';

Matcher refused([String? containing]) =>
    throwsA(isA<HostKeyValueError>().having((e) => e.message, 'message', containing == null ? anything : contains(containing)));

void main() {
  test('a bare fingerprint, padded or not', () {
    expect(parseHostKeyValue(fp1).fingerprints, [fp1]);
    expect(parseHostKeyValue('$fp1=').fingerprints, [fp1]);
    expect(parseHostKeyValue(fp1).host, isNull);
  });

  test('ssh-keygen -lf lines', () {
    final v = parseHostKeyValue('256 $fp1 root@vm (ED25519)\r\n3072 $fp2 root@vm (RSA)\n256 $fp1 again (ED25519)');
    expect(v.fingerprints, [fp1, fp2]);
  });

  test('refused: MD5, malformed, non-canonical, none', () {
    expect(() => parseHostKeyValue('2048 MD5:12:34 root@vm (RSA)'), refused('MD5'));
    expect(() => parseHostKeyValue('SHA256:abc'), refused('malformed'));
    expect(() => parseHostKeyValue('SHA256:MIZwCEPC1dHnGiEluHzU2d3d+fxDOWvqq76It20c4Wl'), refused('malformed'));
    expect(() => parseHostKeyValue('hello'), refused('no SHA256'));
    expect(() => parseHostKeyValue(''), refused());
  });

  test('the QR payload', () {
    final v = parseHostKeyValue('pylon-hostkey/1 Example.ORG:2222 $fp1 $fp2');
    expect(v.host, 'example.org');
    expect(v.port, 2222);
    expect(v.fingerprints, [fp1, fp2]);
    final w = parseHostKeyValue(hostKeyPayload('h.example', 22, [fp2]));
    expect(w.host, 'h.example');
    expect(w.port, isNull);
    expect(hostKeyPayload('h', 2200, [fp1]), 'pylon-hostkey/1 h:2200 $fp1');
  });

  test('the QR payload is strict', () {
    expect(() => parseHostKeyValue('pylon-hostkey/1 example.org'), refused());
    expect(() => parseHostKeyValue('pylon-hostkey/1 example.org $fp1 (ED25519)'), refused('other than'));
    expect(() => parseHostKeyValue('pylon-hostkey/1 example.org:0 $fp1'), refused('HOST:PORT'));
    expect(() => parseHostKeyValue('pylon-hostkey/1 exa\$mple.org $fp1'), refused('HOST:PORT'));
    expect(() => parseHostKeyValue('pylon-hostkey/2 example.org $fp1'), refused('unknown payload version'));
    expect(() => parseHostKeyValue('pylon-hostkey/1 h ${List.filled(9, fp1).join(' ')}'), refused('more than 8'));
  });
}
