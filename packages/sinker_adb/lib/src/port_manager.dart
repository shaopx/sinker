import 'adb_client.dart';

/// Manages ADB port forwarding lifecycle.
///
/// Uses `adb forward tcp:LOCAL tcp:REMOTE` to create a TCP tunnel
/// through USB, allowing TCP connections to reach the Android app.
class PortManager {
  final AdbClient _client;

  PortManager(this._client);

  /// Set up port forwarding: PC localPort → Android remotePort.
  Future<void> forward({
    required int localPort,
    required int remotePort,
    String? deviceSerial,
  }) async {
    await _client.run(
      ['forward', 'tcp:$localPort', 'tcp:$remotePort'],
      deviceSerial: deviceSerial,
    );
  }

  /// Remove a specific port forwarding rule.
  Future<void> removeForward({
    required int localPort,
    String? deviceSerial,
  }) async {
    try {
      await _client.run(
        ['forward', '--remove', 'tcp:$localPort'],
        deviceSerial: deviceSerial,
      );
    } catch (_) {
      // Ignore if already removed
    }
  }

  /// Remove all port forwarding rules.
  Future<void> removeAllForwards({String? deviceSerial}) async {
    try {
      await _client.run(
        ['forward', '--remove-all'],
        deviceSerial: deviceSerial,
      );
    } catch (_) {
      // Ignore errors
    }
  }

  /// List current port forwarding rules.
  Future<List<ForwardRule>> listForwards({String? deviceSerial}) async {
    final result = await _client.run(
      ['forward', '--list'],
      deviceSerial: deviceSerial,
    );

    final rules = <ForwardRule>[];
    for (final line in result.stdout.toString().split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 3) {
        rules.add(ForwardRule(
          serial: parts[0],
          local: parts[1],
          remote: parts[2],
        ));
      }
    }
    return rules;
  }
}

/// A single ADB port forwarding rule.
class ForwardRule {
  final String serial;
  final String local;
  final String remote;

  const ForwardRule({
    required this.serial,
    required this.local,
    required this.remote,
  });

  @override
  String toString() => '$serial: $local → $remote';
}
