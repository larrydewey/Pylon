import 'demo_backend.dart';
import 'model.dart';

Future<Backend> makeBackend() async => DemoBackend();

Future<void> setSecure(bool on) async {}
