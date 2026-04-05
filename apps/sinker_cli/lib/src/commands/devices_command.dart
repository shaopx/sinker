import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:sinker_adb/sinker_adb.dart';

import '../config/settings.dart';

/// List connected Android devices.
class DevicesCommand extends Command<void> {
  @override
  final name = 'devices';

  @override
  final description = 'List connected Android devices.';

  DevicesCommand() {
    argParser.addFlag('json', help: 'Output in JSON format.', negatable: false);
  }

  @override
  Future<void> run() async {
    final settings = Settings.load();
    final client = AdbClient(adbPath: settings.adbPath);

    if (!await client.isAvailable()) {
      print('Error: adb not found at "${settings.adbPath}".');
      print('Install Android SDK Platform Tools or set adb_path in config.');
      return;
    }

    final scanner = DeviceScanner(client);
    final devices = await scanner.listDevices();

    if (argResults?['json'] == true) {
      print(const JsonEncoder.withIndent('  ').convert(
        devices
            .map((d) => {
                  'serial': d.serial,
                  'state': d.state,
                  'model': d.model,
                  'product': d.product,
                })
            .toList(),
      ));
      return;
    }

    if (devices.isEmpty) {
      print('No devices found. Is USB debugging enabled?');
      return;
    }

    print('Connected devices:');
    for (final device in devices) {
      final status = device.isOnline ? 'online' : device.state;
      final model = device.model != null ? ' (${device.model})' : '';
      print('  ${device.serial}  $status$model');
    }
  }
}
