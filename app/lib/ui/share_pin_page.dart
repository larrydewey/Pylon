import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

import '../backend/hostkey_qr.dart';
import '../backend/model.dart';
import '../theme.dart';
import 'access_help.dart';

/// A host's pins as the payload another device pins from (SPEC 6.1.4),
/// as a QR code and as text. The other device still connects and pins
/// only a key the host presents: the code by itself trusts nothing.
class SharePinPage extends StatelessWidget {
  const SharePinPage({super.key, required this.host, required this.pins});
  final Host host;
  final List<Pin> pins;

  @override
  Widget build(BuildContext context) {
    final payload = hostKeyPayload(host.address, host.port, [for (final p in pins) p.fingerprint]);
    return Scaffold(
      appBar: AppBar(title: Text('Share pin · ${host.name}')),
      body: LayoutBuilder(
        builder: (context, box) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          const Para('On the other device, add this host in Pylon (same address and port), tap it to pin it, and choose Scan QR code, or paste the text below.', top: 0),
          const SizedBox(height: 16),
          Center(child: QrView(payload, size: (box.maxWidth - 32).clamp(160.0, 360.0))),
          const SizedBox(height: 16),
          CopyLine(payload, what: 'Pin copied'),
          const SizedBox(height: 12),
          for (final p in pins) Text('${p.alg} ${p.fingerprint}', style: const TextStyle(fontFamily: mono, fontSize: 12, color: P.muted)),
          const Para('Nothing secret is in it: only the host and its key fingerprints. The other device still connects and pins the key only if the host presents a matching one. '
              'On a computer, pylon pin takes the same text in place of a fingerprint.'),
        ]),
      ),
    );
  }
}

/// A QR code for [data]: dark modules on white with a four-module quiet
/// zone, whatever the theme, so cameras read it.
class QrView extends StatelessWidget {
  const QrView(this.data, {super.key, this.size = 260});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final img = QrImage(QrCode(payload: QrPayload.fromString(data)));
    return Semantics(
      label: 'QR code',
      child: SizedBox(width: size, height: size, child: CustomPaint(painter: _QrPainter(img))),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.img);
  final QrImage img;

  @override
  void paint(Canvas canvas, Size s) {
    final n = img.moduleCount + 8; // four modules of quiet zone each side
    final m = s.width / n;
    canvas.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFFFFFFF));
    final dark = Paint()..color = const Color(0xFF000000);
    for (var r = 0; r < img.moduleCount; r++) {
      for (var c = 0; c < img.moduleCount; c++) {
        if (img.isDark(r, c)) canvas.drawRect(Rect.fromLTWH((c + 4) * m, (r + 4) * m, m + 0.5, m + 0.5), dark);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.img != img;
}
