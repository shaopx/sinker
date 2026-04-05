import 'dart:io';

/// Low-level ADB command execution wrapper.
///
/// All ADB interactions go through this class, making it easy to
/// log, mock, and debug ADB commands.
class AdbClient {
  final String adbPath;

  AdbClient({this.adbPath = 'adb'});

  /// Check if adb is available.
  Future<bool> isAvailable() async {
    try {
      final result = await run(['version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Get adb version string.
  Future<String> version() async {
    final result = await run(['version']);
    return result.stdout.toString().trim();
  }

  /// Run an adb command with optional device serial.
  Future<ProcessResult> run(
    List<String> args, {
    String? deviceSerial,
  }) async {
    final fullArgs = <String>[
      if (deviceSerial != null) ...['-s', deviceSerial],
      ...args,
    ];

    final result = await Process.run(adbPath, fullArgs);

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw AdbException(
        'adb ${fullArgs.join(' ')} failed (exit ${result.exitCode}): $stderr',
      );
    }

    return result;
  }

  /// Run an adb shell command on device.
  Future<String> shell(String command, {String? deviceSerial}) async {
    final result = await run(['shell', command], deviceSerial: deviceSerial);
    return result.stdout.toString().trim();
  }
}

/// Exception thrown when an ADB command fails.
class AdbException implements Exception {
  final String message;
  AdbException(this.message);

  @override
  String toString() => 'AdbException: $message';
}
