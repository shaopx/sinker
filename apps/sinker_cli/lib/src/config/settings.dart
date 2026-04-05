import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sinker_core/sinker_core.dart';

/// Application settings, loaded from ~/.sinker/config.json.
class Settings {
  String adbPath;
  String defaultTargetDir;
  String password;
  int port;
  int chunkSize;

  Settings({
    this.adbPath = 'adb',
    this.defaultTargetDir = defaultTargetDir_,
    this.password = defaultPassword,
    this.port = defaultPort,
    this.chunkSize = defaultChunkSize,
  });

  static const defaultTargetDir_ = '/sdcard/Download/sinker/';

  /// Path to config file.
  static String get configPath {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return p.join(home, '.sinker', 'config.json');
  }

  /// Load settings from config file, or return defaults.
  static Settings load() {
    final file = File(configPath);
    if (!file.existsSync()) return Settings();

    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return Settings(
        adbPath: json['adb_path'] as String? ?? 'adb',
        defaultTargetDir: json['target_dir'] as String? ?? defaultTargetDir_,
        password: json['password'] as String? ?? defaultPassword,
        port: json['port'] as int? ?? defaultPort,
        chunkSize: json['chunk_size'] as int? ?? defaultChunkSize,
      );
    } catch (_) {
      return Settings();
    }
  }

  /// Save settings to config file.
  void save() {
    final file = File(configPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'adb_path': adbPath,
      'target_dir': defaultTargetDir,
      'password': password,
      'port': port,
      'chunk_size': chunkSize,
    }));
  }

  Map<String, dynamic> toJson() => {
        'adb_path': adbPath,
        'target_dir': defaultTargetDir,
        'password': password,
        'port': port,
        'chunk_size': chunkSize,
      };

  @override
  String toString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}
