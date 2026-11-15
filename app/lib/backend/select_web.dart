import 'demo_backend.dart';
import 'model.dart';

Future<Backend> makeBackend() async => DemoBackend();

Future<void> setSecure(bool on) async {}

bool get desktopLayout => false;

String get deviceName => 'this device';

String get agentNote => 'Demo';
