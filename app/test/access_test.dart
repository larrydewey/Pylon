// Getting a key into a host: the core's refusal read into keys and
// commands, pasted key lines checked before anything connects, and
// `pylon authorize`'s report.
import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/access.dart';

const ed = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGGi3CwEyRfKgW8t8sKj5fNcQ4/YUz/8mory7yZuj40I alice@laptop';
const ecdsa =
    'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBN9nnJmlRTcqB1/TxR8N/iyViX8RNuQUWDnDAW9i1I7zp6xy37gMBnBilSmaNC/YcdvZ5NisOt4ObPWq9GH+R/Q= symbolon-pylon-2026-11-22';

const refusal = '''pylon: larry@nas.lan accepted none of the agent's keys.
Offered:
  $ecdsa
  certificate ssh-ed25519-cert-v01@openssh.com SHA256:abc signed by SHA256:def
  $ed
The server accepts publickey; it may also refuse a key when ~/.ssh is writable by others.
To let a key in, run this on a device that can already log in to nas.lan:
  pylon authorize -p 2222 larry@nas.lan '$ecdsa'
Or append the key line to ~/.ssh/authorized_keys on nas.lan yourself, then run
  chmod go-w ~ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
''';

void main() {
  group('the refusal', () {
    test('is found by its words, anywhere in the messages', () {
      expect(parseKeyRefusal('pylon: host key not pinned'), isNull);
      expect(parseKeyRefusal(''), isNull);
      expect(parseKeyRefusal('pylond 0.2.12 checked\n$refusal'), isNotNull);
    });

    test('gives the target, the keys, the command and the fix', () {
      final r = parseKeyRefusal(refusal)!;
      expect(r.target, 'larry@nas.lan');
      expect(r.keys, [ecdsa, ed]);
      expect(r.certificates, 1);
      expect(r.commands, ["pylon authorize -p 2222 larry@nas.lan '$ecdsa'"]);
      expect(r.fix, 'chmod go-w ~ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys');
      expect(r.notes, ['The server accepts publickey; it may also refuse a key when ~/.ssh is writable by others.']);
      expect(r.raw, refusal.trim());
    });

    test('lines that only look like keys are not keys', () {
      final r = parseKeyRefusal("pylon: u@h accepted none of the agent's keys.\nOffered:\n ssh-ed25519 AAAA one-space\n  ssh-ed25519 AAAA two words\n  ssh-ed25519 AA!A x\n")!;
      expect(r.keys, isEmpty);
    });

    test('a refusal cut short still reads', () {
      final r = parseKeyRefusal("pylon: u@h accepted none of the agent's keys.\nOffered:\n  $ed")!;
      expect(r.keys, [ed]);
      expect(r.commands, isEmpty);
      expect(r.fix, isNull);
    });

    test('the command, when the core gave none, quotes each key', () {
      expect(authorizeCommand('u@h', 22, '', [ed]), "pylon authorize u@h '$ed'");
      expect(authorizeCommand('u@h', 2222, 'j@jump', [ed, ecdsa]), "pylon authorize -p 2222 -J j@jump u@h '$ed' '$ecdsa'");
    });
  });

  group('pasted key lines', () {
    test('good lines, with or without a comment', () {
      expect(keyLineProblem(ed), isNull);
      expect(keyLineProblem(ecdsa), isNull);
      expect(keyLineProblem(ed.substring(0, ed.lastIndexOf(' '))), isNull);
    });

    test('what is wrong is said', () {
      expect(keyLineProblem('hello there'), contains('not a public key line'));
      expect(keyLineProblem('from="10.0.0.1" $ed'), contains('options before the key type'));
      expect(keyLineProblem('$ed and more words'), isNull);
      expect(keyLineProblem('ssh-ed25519-cert-v01@openssh.com AAAAC3NzaC1lZDI1NTE5AAAAIGGi3CwEyRfKgW8t8sKj5fNcQ4/YUz/8mory7yZuj40I x'), contains('certificate'));
      // Cut short: no longer base64 of whole bytes.
      expect(keyLineProblem('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGGi3CwEyRfKgW8t8sKj5fNc x'), isNotNull);
      // A key of another type under this name.
      expect(keyLineProblem('ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIGGi3CwEyRfKgW8t8sKj5fNcQ4/YUz/8mory7yZuj40I x'), contains('not a ssh-rsa key'));
    });

    test('a paste: blank lines and comments skipped, spaces evened, the same key once', () {
      final r = parseKeyLines('# my keys\n\n  $ed  \n${ecdsa.replaceFirst(' ', '\t')}\n${ed.substring(0, ed.lastIndexOf(' '))} other\n');
      expect(r.problems, isEmpty);
      expect(r.keys, [ed, ecdsa]);
    });

    test('a paste with a bad line names it', () {
      final r = parseKeyLines('$ed\nnot a key\n');
      expect(r.keys, [ed]);
      expect(r.problems, hasLength(1));
      expect(r.problems.first, startsWith('Line 2:'));
    });
  });

  test("authorize's report", () {
    final a = parseReportLine('added ssh-ed25519 SHA256:abc alice@laptop');
    expect(a.kind, ReportKind.added);
    expect(a.text, 'ssh-ed25519 SHA256:abc alice@laptop');
    expect(parseReportLine('present ecdsa-sha2-nistp256 SHA256:def').kind, ReportKind.present);
    expect(parseReportLine('fixed ~/.ssh was 755, now 700').text, '~/.ssh was 755, now 700');
    expect(parseReportLine('warning authorized_keys had Windows line endings').kind, ReportKind.warning);
    expect(parseReportLine('done').kind, ReportKind.done);
    final o = parseReportLine('something new');
    expect(o.kind, ReportKind.other);
    expect(o.text, 'something new');
  });
}
