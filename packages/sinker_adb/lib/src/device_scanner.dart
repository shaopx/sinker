import 'adb_client.dart';

/// Represents a connected Android device.
class AdbDevice {
  final String serial;
  final String state; // "device", "offline", "unauthorized"
  final String? model;
  final String? product;

  const AdbDevice({
    required this.serial,
    required this.state,
    this.model,
    this.product,
  });

  bool get isOnline => state == 'device';

  @override
  String toString() => 'AdbDevice($serial, $state${model != null ? ', $model' : ''})';
}

/// Discovers connected Android devices.
class DeviceScanner {
  final AdbClient _client;

  DeviceScanner(this._client);

  /// List all connected devices.
  Future<List<AdbDevice>> listDevices() async {
    final result = await _client.run(['devices', '-l']);
    final output = result.stdout.toString();

    final devices = <AdbDevice>[];
    for (final line in output.split('\n')) {
      if (line.startsWith('List of') || line.trim().isEmpty) continue;

      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;

      final serial = parts[0];
      final state = parts[1];

      String? model;
      String? product;
      for (final part in parts.skip(2)) {
        if (part.startsWith('model:')) {
          model = part.substring(6);
        } else if (part.startsWith('product:')) {
          product = part.substring(8);
        }
      }

      devices.add(AdbDevice(
        serial: serial,
        state: state,
        model: model,
        product: product,
      ));
    }

    return devices;
  }

  /// Get a single online device. Throws if none or multiple found.
  Future<AdbDevice> getSingleDevice() async {
    final devices = await listDevices();
    final online = devices.where((d) => d.isOnline).toList();

    if (online.isEmpty) {
      throw AdbException('No connected devices found. Is USB debugging enabled?');
    }
    if (online.length > 1) {
      final serials = online.map((d) => d.serial).join(', ');
      throw AdbException(
        'Multiple devices found ($serials). Use --device to specify one.',
      );
    }

    return online.first;
  }
}
