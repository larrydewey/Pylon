import 'dart:io';

import 'package:flutter/services.dart';

import 'demo_backend.dart';
import 'model.dart';
import 'process_backend.dart';

const platform = MethodChannel('pylon/platform');

/// The core's binaries. Android: libpylon.so and libpylon_term.so in the
/// native library directory, the pylond builds unpacked from the app's
/// assets, PYLON_HOME in the app's private files. Desktop: PYLON_BIN_DIR,
/// else beside this executable, and PYLON_HOME as the command-line client
/// uses it. With PYLON_DEMO=1, or no core found, the demo backend (which
/// says so on every screen).
Future<Backend> makeBackend() async {
  if (Platform.isAndroid) {
    final p = Map<String, String>.from(await platform.invokeMethod('paths') as Map);
    final bin = p['bin']!, files = p['files']!;
    final pylond = '$files/pylond';
    await Directory(pylond).create(recursive: true);
    for (final arch in ['x86_64', 'aarch64']) {
      final data = await rootBundle.load('assets/pylond/pylond-$arch');
      await File('$pylond/pylond-$arch').writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    return ProcessBackend.at('$bin/libpylon.so', '$bin/libpylon_term.so', pylond, '$files/pylon',
        agent: (conn, req) async => await platform.invokeMethod<Uint8List>('agent', {'conn': conn, 'request': req}),
        agentClose: (conn) => platform.invokeMethod('agentClose', conn));
  }
  final env = Platform.environment;
  if (env['PYLON_DEMO'] == '1') return DemoBackend();
  final bin = env['PYLON_BIN_DIR'] ?? File(Platform.resolvedExecutable).parent.path;
  final home = env['PYLON_HOME'] ?? '${env['HOME'] ?? '.'}/.config/pylon';
  if (!File('$bin/pylon').existsSync() || !File('$bin/pylon-term').existsSync()) return DemoBackend();
  return ProcessBackend(bin, home);
}

/// Keeps terminal content out of screenshots and recents (Android).
Future<void> setSecure(bool on) async {
  if (Platform.isAndroid) await platform.invokeMethod('secure', on);
}
