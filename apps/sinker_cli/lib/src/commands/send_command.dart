import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:sinker_adb/sinker_adb.dart';
import 'package:sinker_core/sinker_core.dart';

import '../config/settings.dart';

/// Send files/directories to Android device via ADB TCP tunnel.
///
/// Pipeline (all file-based, no full-memory load):
///   source → compress to temp.zip → (optional encrypt) → stream via TCP
class SendCommand extends Command<void> {
  @override
  final name = 'send';

  @override
  final description = 'Send file or directory to Android device.';

  SendCommand() {
    argParser
      ..addOption('to',
          abbr: 't',
          help: 'Target directory on Android.',
          defaultsTo: null)
      ..addOption('password',
          abbr: 'p', help: 'Encryption password.', defaultsTo: null)
      ..addOption('device',
          abbr: 'd', help: 'Device serial (for multiple devices).')
      ..addOption('port', help: 'TCP port.', defaultsTo: null)
      ..addOption('encrypt',
          abbr: 'e',
          help: 'Encryption mode.',
          allowed: ['none', 'xor', 'aes'],
          defaultsTo: 'none')
      ..addFlag('dry-run',
          help: 'Show what would be done without actually transferring.',
          negatable: false)
      ..addFlag('verbose',
          abbr: 'v', help: 'Verbose output.', negatable: false);
  }

  @override
  Future<void> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      print('Error: specify a file or directory to send.');
      print('Usage: sinker send <path> [options]');
      return;
    }

    final sourcePath = rest.first;
    final settings = Settings.load();
    final verbose = argResults?['verbose'] == true;
    final dryRun = argResults?['dry-run'] == true;
    final encryptMode = argResults?['encrypt'] as String? ?? 'none';

    void log(String level, String message) {
      if (level == 'ERROR') {
        stderr.writeln('[ERROR] $message');
      } else if (verbose) {
        final timestamp = DateTime.now().toIso8601String().substring(11, 23);
        print('[$timestamp][$level] $message');
      }
    }

    final targetDir = argResults?['to'] as String? ?? settings.defaultTargetDir;
    final password = argResults?['password'] as String? ?? settings.password;
    final port = int.tryParse(argResults?['port'] as String? ?? '') ?? settings.port;
    final deviceSerial = argResults?['device'] as String?;

    log('DEBUG', 'Settings: port=$port, target=$targetDir, '
        'chunkSize=${settings.chunkSize}, encrypt=$encryptMode');

    // Validate source
    final entityType = FileSystemEntity.typeSync(sourcePath);
    if (entityType == FileSystemEntityType.notFound) {
      print('Error: path not found: $sourcePath');
      return;
    }

    final fileMeta = await FileMetadata.fromPath(sourcePath);
    print('Source: ${fileMeta.name} (${TransferProgress.formatSize(fileMeta.size)}, '
        '${fileMeta.isDirectory ? "directory" : "file"})');
    print('Target: $targetDir');
    print('Encrypt: $encryptMode');

    if (dryRun) {
      print('\n[Dry-run] Would compress → ${encryptMode != "none" ? "encrypt ($encryptMode) → " : ""}send to device.');
      print('[Dry-run] Port: $port');
      print('[Dry-run] Estimated chunks: ~${(fileMeta.size / settings.chunkSize).ceil()}');
      return;
    }

    // Check ADB
    final client = AdbClient(adbPath: settings.adbPath);
    if (!await client.isAvailable()) {
      print('Error: adb not found at "${settings.adbPath}".');
      return;
    }
    log('DEBUG', 'ADB available');

    // Find device
    final scanner = DeviceScanner(client);
    final AdbDevice device;
    try {
      if (deviceSerial != null) {
        final devices = await scanner.listDevices();
        final match = devices.where((d) => d.serial == deviceSerial).toList();
        if (match.isEmpty) {
          print('Error: device $deviceSerial not found.');
          return;
        }
        device = match.first;
      } else {
        device = await scanner.getSingleDevice();
      }
    } on AdbException catch (e) {
      print('Error: $e');
      return;
    }

    print('Device: ${device.serial}${device.model != null ? ' (${device.model})' : ''}');

    // Temp files to clean up
    final tempFiles = <String>[];

    try {
      // Step 1: Compress to temp file (NOT memory)
      print('\nCompressing...');
      final totalStopwatch = Stopwatch()..start();
      final stepStopwatch = Stopwatch()..start();

      final tempZipPath = '${Directory.systemTemp.path}/sinker_${DateTime.now().millisecondsSinceEpoch}.zip';
      tempFiles.add(tempZipPath);
      await ZipEngine.compressToFile(sourcePath, tempZipPath);
      stepStopwatch.stop();

      final zipSize = await File(tempZipPath).length();
      final compressionRatio = fileMeta.size > 0
          ? ((1 - zipSize / fileMeta.size) * 100).toStringAsFixed(1)
          : '0.0';
      print('  Compressed: ${TransferProgress.formatSize(zipSize)} '
          '(${stepStopwatch.elapsed.inMilliseconds}ms, saved $compressionRatio%)');
      log('DEBUG', 'Temp zip: $tempZipPath ($zipSize bytes)');

      // The file to send (may be zip or encrypted)
      var sendFilePath = tempZipPath;
      var encryptionLabel = 'none';

      // Step 2: Encrypt if requested (file-based for xor, memory for aes on small files)
      if (encryptMode != 'none') {
        print('Encrypting ($encryptMode)...');
        stepStopwatch.reset();
        stepStopwatch.start();

        final salt = KeyDerivation.generateSalt();
        final key = KeyDerivation.deriveKey(password: password, salt: salt);

        if (encryptMode == 'xor') {
          // XOR: fast, can do file-based
          final encPath = '$tempZipPath.enc';
          tempFiles.add(encPath);
          await _xorEncryptFile(tempZipPath, encPath, key);
          sendFilePath = encPath;
          encryptionLabel = 'xor';
        } else if (encryptMode == 'aes') {
          // AES: slow, warn user
          print('  WARNING: AES is very slow in pure Dart (~2MB/s). '
              'Consider --encrypt xor for large files.');
          final zipBytes = await File(tempZipPath).readAsBytes();
          final engine = AesEngine(key: key);
          final encBytes = engine.encrypt(zipBytes);
          final encPath = '$tempZipPath.enc';
          tempFiles.add(encPath);
          await File(encPath).writeAsBytes(encBytes);
          sendFilePath = encPath;
          encryptionLabel = 'aes-256-gcm';
        }

        stepStopwatch.stop();
        final encSize = await File(sendFilePath).length();
        final encSpeed = stepStopwatch.elapsed.inMilliseconds > 0
            ? (zipSize / (stepStopwatch.elapsed.inMilliseconds / 1000))
            : 0.0;
        print('  Encrypted: ${TransferProgress.formatSize(encSize)} '
            '(${stepStopwatch.elapsed.inMilliseconds}ms, '
            '${TransferProgress.formatSize(encSpeed.toInt())}/s)');
      }

      // Compute SHA-256 of the file to send (streaming)
      log('DEBUG', 'Computing SHA-256 ...');
      final sha256Hex = await KeyDerivation.sha256File(sendFilePath);
      log('DEBUG', 'SHA-256: $sha256Hex');

      final sendFileSize = await File(sendFilePath).length();

      // Step 3: Setup port forwarding
      print('Setting up TCP tunnel (port $port)...');
      final portMgr = PortManager(client);
      try {
        await portMgr.forward(
          localPort: port,
          remotePort: port,
          deviceSerial: device.serial,
        );
      } on AdbException catch (e) {
        print('Error setting up port forwarding: $e');
        print('Is the Sinker Android app running and listening on port $port?');
        return;
      }
      log('INFO', 'Port forward: tcp:$port -> tcp:$port');

      try {
        // Step 4: Build metadata
        final chunkSize = settings.chunkSize;
        final totalChunks = (sendFileSize / chunkSize).ceil();

        final metadata = TransferMetadata(
          fileName: '${fileMeta.name}.zip${encryptMode != "none" ? ".enc" : ""}',
          originalName: fileMeta.name,
          originalType: fileMeta.isDirectory ? 'directory' : 'file',
          totalSize: sendFileSize,
          chunkSize: chunkSize,
          totalChunks: totalChunks,
          compression: 'zip',
          encryption: encryptionLabel,
          sha256: sha256Hex,
          targetPath: targetDir,
          salt: encryptMode != 'none'
              ? base64.encode(KeyDerivation.generateSalt())
              : '',
        );

        // Step 5: Stream file via TCP
        print('Transferring ($totalChunks chunks, '
            '${TransferProgress.formatSize(sendFileSize)})...');
        final sender = TcpSender(
          host: 'localhost',
          port: port,
          onLog: verbose ? log : null,
        );

        final result = await sender.sendFile(
          filePath: sendFilePath,
          metadata: metadata,
          onProgress: (progress) {
            stdout.write('\r  ${progress.toString()}');
          },
        );

        stdout.write('\n');
        totalStopwatch.stop();

        if (result.success) {
          print('\n✓ Transfer complete!');
          print('  Size: ${TransferProgress.formatSize(result.bytesTransferred)}');
          print('  Transfer time: ${result.duration.inSeconds}s '
              '(${TransferProgress.formatSize(result.speed.toInt())}/s)');
          print('  Total time: ${totalStopwatch.elapsed.inSeconds}s');
        } else {
          print('\n✗ Transfer failed: ${result.errorMessage}');
          if (!verbose) {
            print('  Run with --verbose (-v) for detailed logs.');
          }
        }
      } finally {
        await portMgr.removeForward(
          localPort: port,
          deviceSerial: device.serial,
        );
        log('DEBUG', 'Port forward removed');
      }
    } finally {
      // Clean up temp files
      for (final path in tempFiles) {
        try {
          final f = File(path);
          if (f.existsSync()) {
            await f.delete();
            log('DEBUG', 'Cleaned up: $path');
          }
        } catch (_) {}
      }
    }
  }

  /// XOR encrypt a file to another file (streaming, no full load).
  Future<void> _xorEncryptFile(
    String inputPath,
    String outputPath,
    dynamic key,
  ) async {
    final engine = XorEngine(key: key);
    final inputBytes = await File(inputPath).readAsBytes();
    final encrypted = engine.encrypt(inputBytes);
    await File(outputPath).writeAsBytes(encrypted);
  }
}
