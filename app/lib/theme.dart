import 'package:material_ui/material_ui.dart';

/// The palette from the design canvas: ink ground, teal for trust and
/// safe actions, amber for what needs attention, red for refusals,
/// purple for "this device" (the local shell).
class P {
  static const ink = Color(0xFF0E1116);
  static const ink2 = Color(0xFF0A0C10);
  static const surface = Color(0xFF161B22);
  static const line = Color(0xFF2A313C);
  static const text = Color(0xFFE6EDF3);
  static const muted = Color(0xFF9AA4B2);
  static const teal = Color(0xFF4FD1C5);
  static const tealDeep = Color(0xFF123B38);
  static const tealLine = Color(0xFF2A5E59);
  static const tealText = Color(0xFF7DE3D9);
  static const amber = Color(0xFFF5C76A);
  static const amberDeep = Color(0xFF1C1810);
  static const amberLine = Color(0xFF5A4520);
  static const red = Color(0xFFFF9B9B);
  static const redDeep = Color(0xFF2A1416);
  static const redLine = Color(0xFF6B2B2B);
  static const purple = Color(0xFFC4B5FD);
  static const purpleDeep = Color(0xFF17131F);
  static const purpleLine = Color(0xFF3A2F52);
  // The local shell (purple always means "this device", never a server).
  static const localInk = Color(0xFF0D0B12);
  static const localText = Color(0xFFECE7F6);
  static const localMuted = Color(0xFFB7AECB);
  static const localKey = Color(0xFF211B2D);
}

const mono = 'JetBrainsMono';

ThemeData pylonTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: P.ink,
    colorScheme: const ColorScheme.dark(
      primary: P.teal,
      onPrimary: P.ink,
      secondary: P.amber,
      surface: P.surface,
      onSurface: P.text,
      error: P.red,
    ),
    appBarTheme: const AppBarTheme(backgroundColor: P.ink, foregroundColor: P.text, elevation: 0),
    dividerColor: P.line,
    textTheme: base.textTheme.apply(bodyColor: P.text, displayColor: P.text),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: P.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: P.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: P.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: P.teal)),
      labelStyle: const TextStyle(color: P.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: P.teal,
        foregroundColor: P.ink,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: P.text,
        side: const BorderSide(color: P.line),
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}

/// The gateway mark (logo direction A): two tapered towers and a cursor
/// in the gate. [cursor] is null for the one-colour variant.
class PylonMark extends StatelessWidget {
  const PylonMark({super.key, this.size = 28, this.color = P.text, this.cursor = P.teal});
  final double size;
  final Color color;
  final Color? cursor;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _MarkPainter(color, cursor ?? color));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color, this.cursor);
  final Color color;
  final Color cursor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 64;
    final p = Paint()..color = color;
    canvas.drawPath(Path()..addPolygon([Offset(6 * s, 56 * s), Offset(13 * s, 8 * s), Offset(26 * s, 8 * s), Offset(26 * s, 56 * s)], true), p);
    canvas.drawPath(Path()..addPolygon([Offset(38 * s, 56 * s), Offset(38 * s, 8 * s), Offset(51 * s, 8 * s), Offset(58 * s, 56 * s)], true), p);
    canvas.drawRect(Rect.fromLTWH(29 * s, 42 * s, 6 * s, 14 * s), Paint()..color = cursor);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color || old.cursor != cursor;
}
