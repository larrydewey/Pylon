import 'package:flutter/material.dart';

import '../theme.dart';

class Chip2 extends StatelessWidget {
  const Chip2(this.label, {super.key, this.fg = P.tealText, this.bg = P.tealDeep});
  final String label;
  final Color fg, bg;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
      );
}

class Section extends StatelessWidget {
  const Section(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
        child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: P.muted)),
      );
}

class Card2 extends StatelessWidget {
  const Card2({super.key, required this.child, this.border = P.line, this.color = P.surface, this.onTap, this.padding = const EdgeInsets.all(14)});
  final Widget child;
  final Color border, color;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

class Row2 extends StatelessWidget {
  const Row2(this.k, this.v, {super.key, this.monoValue = false});
  final String k, v;
  final bool monoValue;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Text(k, style: const TextStyle(color: P.muted, fontSize: 14)),
          const SizedBox(width: 12),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: TextStyle(fontSize: monoValue ? 12 : 14, fontFamily: monoValue ? mono : null, fontWeight: FontWeight.w500))),
        ]),
      );
}

/// Text from a host or the core, shown with control characters made
/// visible (never interpreted), SPEC 11 and 12.
String visible(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final bidi = (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) || r == 0x200E || r == 0x200F;
    if ((r < 0x20 && r != 0x0a) || r == 0x7f || bidi) {
      b.write('<U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}>');
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}
