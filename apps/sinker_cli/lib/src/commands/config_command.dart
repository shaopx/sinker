import 'package:args/command_runner.dart';

import '../config/settings.dart';

/// View and manage configuration.
class ConfigCommand extends Command<void> {
  @override
  final name = 'config';

  @override
  final description = 'View or modify configuration.';

  ConfigCommand() {
    argParser
      ..addFlag('list',
          abbr: 'l', help: 'List all settings.', negatable: false)
      ..addOption('set',
          help: 'Set a config value (key=value).', valueHelp: 'key=value')
      ..addOption('get', help: 'Get a config value.', valueHelp: 'key');
  }

  @override
  Future<void> run() async {
    final settings = Settings.load();

    if (argResults?['list'] == true) {
      print('Config file: ${Settings.configPath}');
      print(settings.toString());
      return;
    }

    final getValue = argResults?['get'] as String?;
    if (getValue != null) {
      final map = settings.toJson();
      if (map.containsKey(getValue)) {
        print(map[getValue]);
      } else {
        print('Unknown key: $getValue');
        print('Available keys: ${map.keys.join(', ')}');
      }
      return;
    }

    final setValue = argResults?['set'] as String?;
    if (setValue != null) {
      final parts = setValue.split('=');
      if (parts.length != 2) {
        print('Invalid format. Use: sinker config --set key=value');
        return;
      }
      final key = parts[0].trim();
      final value = parts[1].trim();

      switch (key) {
        case 'adb_path':
          settings.adbPath = value;
        case 'target_dir':
          settings.defaultTargetDir = value;
        case 'password':
          settings.password = value;
        case 'port':
          settings.port = int.tryParse(value) ?? settings.port;
        case 'chunk_size':
          settings.chunkSize = int.tryParse(value) ?? settings.chunkSize;
        default:
          print('Unknown key: $key');
          return;
      }

      settings.save();
      print('Set $key = $value');
      return;
    }

    // Default: show usage
    printUsage();
  }
}
