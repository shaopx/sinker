import 'package:args/command_runner.dart';

import 'commands/send_command.dart';
import 'commands/devices_command.dart';
import 'commands/config_command.dart';

/// Sinker CLI application.
class CliApp extends CommandRunner<void> {
  CliApp()
      : super(
          'sinker',
          'Send files to Android via ADB TCP tunnel.\n'
              'Files are compressed and encrypted before transfer.',
        ) {
    addCommand(SendCommand());
    addCommand(DevicesCommand());
    addCommand(ConfigCommand());
  }
}
