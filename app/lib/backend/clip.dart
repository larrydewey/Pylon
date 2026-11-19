import 'dart:async';

import 'package:flutter/services.dart';

/// Copies from the terminal where the platform cannot mark them sensitive
/// itself (Android does, in MainActivity's "clipCopy"): put on the
/// clipboard, and cleared [after] 60 seconds if the clipboard still holds
/// them (SPEC 15, H5). A newer copy restarts the clock for itself only.
class ExpiringClipboard {
  ExpiringClipboard({this.after = const Duration(seconds: 60)});
  final Duration after;
  Timer? _timer;

  Future<void> copy(String text) async {
    _timer?.cancel();
    await Clipboard.setData(ClipboardData(text: text));
    _timer = Timer(after, () => _expire(text));
  }

  Future<void> _expire(String ours) async {
    _timer = null;
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      // Only ours: what the principal copied elsewhere since is left alone.
      if (now?.text == ours) await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {}
  }
}
