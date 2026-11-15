import 'dart:typed_data';

/// type (1) | length (4, big-endian) | payload, both ways.
Uint8List frame(int type, List<int> payload) {
  final b = BytesBuilder(copy: false)
    ..addByte(type)
    ..add([(payload.length >> 24) & 255, (payload.length >> 16) & 255, (payload.length >> 8) & 255, payload.length & 255])
    ..add(payload);
  return b.toBytes();
}

class FrameReader {
  final _buf = BytesBuilder(copy: true);

  /// Whole frames in what has arrived so far, as (type, payload).
  List<(int, Uint8List)> add(List<int> data) {
    _buf.add(data);
    final all = _buf.takeBytes();
    final out = <(int, Uint8List)>[];
    var at = 0;
    while (all.length - at >= 5) {
      final n = (all[at + 1] << 24) | (all[at + 2] << 16) | (all[at + 3] << 8) | all[at + 4];
      if (n > 16 << 20) return out; // a malformed stream: stop reading it
      if (all.length - at < 5 + n) break;
      out.add((all[at], Uint8List.sublistView(all, at + 5, at + 5 + n)));
      at += 5 + n;
    }
    _buf.add(Uint8List.sublistView(all, at));
    return out;
  }
}
