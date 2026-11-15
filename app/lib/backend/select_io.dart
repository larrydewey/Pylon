import 'dart:io';

import 'demo_backend.dart';
import 'model.dart';
import 'process_backend.dart';

/// The core's binaries: PYLON_BIN_DIR, else beside this executable (a
/// desktop bundle). PYLON_HOME as the command-line client uses it. With
/// PYLON_DEMO=1, or no core found, the interface runs on the demo backend
/// (which says so on every screen).
Backend makeBackend() {
  final env = Platform.environment;
  if (env['PYLON_DEMO'] == '1') return DemoBackend();
  final bin = env['PYLON_BIN_DIR'] ?? File(Platform.resolvedExecutable).parent.path;
  final home = env['PYLON_HOME'] ?? '${env['HOME'] ?? '.'}/.config/pylon';
  if (!File('$bin/pylon').existsSync() || !File('$bin/pylon-term').existsSync()) return DemoBackend();
  return ProcessBackend(bin, home);
}
