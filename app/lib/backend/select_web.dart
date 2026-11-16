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
