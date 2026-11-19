import 'dart:typed_data';

import 'demo_backend.dart';
import 'model.dart';

Future<Backend> makeBackend() async => DemoBackend();

Future<void> setSecure(bool on) async {}

bool get desktopLayout => false;

String get deviceName => 'this device';

String get agentNote => 'Demo';

/// No key-holding app in the demo.
Future<bool> openKeyHolder() async => false;

/// Nothing to keep alive in the demo.
Future<void> keepConnections(int live) async {}

abstract class LocalTarget {
  String get label;
  Future<void> write(Uint8List chunk);
  Future<void> finish(bool ok);
}

abstract class LocalSource {
  String get name;
  int? get size;
  Future<Uint8List?> read();
  Future<void> close();
}

/// The demo has no files on the device.
bool get systemPicker => true;
Future<LocalTarget?> pickTarget(String name) async => null;
Future<LocalSource?> pickSource() async => null;
String get downloadsDir => '';
bool localExists(String path) => false;
Future<LocalTarget> pathTarget(String path, {bool replace = false}) => throw UnsupportedError('no files in the demo');
Future<LocalSource> pathSource(String path) => throw UnsupportedError('no files in the demo');
