// What the app reads from its agent's answer to a key request: the card
// that takes the principal to Symbolon depends on it.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pylon/backend/model.dart';
import 'package:pylon/backend/process_backend.dart';

Uint8List answer(int count) => Uint8List.fromList([0, 0, 0, 5, 12, 0, 0, 0, count]);

void main() {
  test('no keys: an identities answer with a count of 0', () {
    expect(keysIn(answer(0)), AgentKeys.none);
  });
  test('some keys', () {
    expect(keysIn(answer(2)), AgentKeys.some);
  });
  test('unreachable: no reply, the failure message, or a short or odd reply', () {
    expect(keysIn(null), AgentKeys.unreachable);
    expect(keysIn(Uint8List.fromList([0, 0, 0, 1, 5])), AgentKeys.unreachable);
    expect(keysIn(Uint8List.fromList([0, 0, 0, 5, 6, 0, 0, 0, 0])), AgentKeys.unreachable);
    expect(keysIn(Uint8List.fromList([0, 0, 0, 2, 12])), AgentKeys.unreachable);
  });
}
