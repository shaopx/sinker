import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:sinker_adb/sinker_adb.dart';
import 'package:sinker_core/sinker_core.dart';

import '../config/settings.dart';

/// File extensions that are already compressed — skip ZIP step.
const _compressedExtensions = {
  '.zip', '.rar', '.7z', '.gz', '.tgz', '.bz2', '.xz', '.zst',
  '.tar.gz', '.tar.bz2', '.tar.xz',
  '.apk', '.aab', '.ipa', // app packages
  '.jar', '.war', // java
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.mp4', '.mkv', '.avi', // media
  '.mp3', '.aac', '.flac', '.ogg',
};

/// Send files/directories to Android device via ADB TCP tunnel.
///
/// Pipeline (all file-based, no full-memory load):
///   source → (compress if needed) → (optional encrypt) → stream via TCP
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
          allowed: ['none', 'xor', 'aes', 'aes-native'],
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
    final isDirectory = fileMeta.isDirectory;
    final skipCompression = !isDirectory && _isAlreadyCompressed(sourcePath);

    print('Source: ${fileMeta.name} (${TransferProgress.formatSize(fileMeta.size)}, '
        '${isDirectory ? "directory" : "file"})');
    print('Target: $targetDir');
    print('Encrypt: $encryptMode');
    if (skipCompression) {
      print('Compression: skipped (already compressed format)');
    }

    if (dryRun) {
      final steps = <String>[];
      if (!skipCompression) steps.add('compress');
      if (encryptMode != 'none') steps.add('encrypt ($encryptMode)');
      steps.add('send');
      print('\n[Dry-run] Would ${steps.join(' → ')} to device.');
      print('[Dry-run] Port: $port');
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
      final totalStopwatch = Stopwatch()..start();
      final stepStopwatch = Stopwatch()..start();

      // ── Step 1: Prepare file to send ──
      String sendFilePath;
      String compressionLabel;

      if (skipCompression) {
        // Already compressed file → send as-is
        sendFilePath = sourcePath;
        compressionLabel = 'none';
        print('\nSkipping compression...');
      } else {
        // Package to temp ZIP using STORED mode (no compression).
        // STORED is essentially disk-read speed; DEFLATE would cap us
        // at ~50 MB/s and is pointless over a local USB tunnel.
        print('\nPackaging (STORED, no compression)...');
        final tempZipPath = '${Directory.systemTemp.path}/sinker_${DateTime.now().millisecondsSinceEpoch}.zip';
        tempFiles.add(tempZipPath);
        await ZipEngine.compressToFile(sourcePath, tempZipPath);
        stepStopwatch.stop();

        final zipSize = await File(tempZipPath).length();
        final overhead = fileMeta.size > 0
            ? ((zipSize / fileMeta.size - 1) * 100).toStringAsFixed(2)
            : '0.00';
        print('  Packaged: ${TransferProgress.formatSize(zipSize)} '
            '(${stepStopwatch.elapsed.inMilliseconds}ms, +$overhead% header overhead)');
        log('DEBUG', 'Temp zip: $tempZipPath ($zipSize bytes)');

        sendFilePath = tempZipPath;
        compressionLabel = 'zip';
      }

      var encryptionLabel = 'none';
      var saltForMetadata = '';

      // ── Step 2: Encrypt if requested ──
      if (encryptMode != 'none') {
        print('Encrypting ($encryptMode)...');
        stepStopwatch.reset();
        stepStopwatch.start();

        final salt = KeyDerivation.generateSalt();
        final key = KeyDerivation.deriveKey(password: password, salt: salt);
        saltForMetadata = base64.encode(salt);

        final encPath = '$sendFilePath.enc';
        tempFiles.add(encPath);

        if (encryptMode == 'xor') {
          await _xorEncryptFile(sendFilePath, encPath, key);
          encryptionLabel = 'xor';
        } else if (encryptMode == 'aes-native') {
          // File-based chunked encryption — no OOM for any file size
          final engine = NativeAesEngine(key: key);
          await engine.encryptFileAsync(sendFilePath, encPath);
          encryptionLabel = 'aes-256-gcm';
        } else if (encryptMode == 'aes') {
          print('  WARNING: AES is very slow in pure Dart (~2MB/s). '
              'Consider --encrypt aes-native for large files.');
          final inputBytes = await File(sendFilePath).readAsBytes();
          final engine = AesEngine(key: key);
          final encBytes = engine.encrypt(inputBytes);
          await File(encPath).writeAsBytes(encBytes);
          encryptionLabel = 'aes-256-gcm';
        }

        sendFilePath = encPath;

        stepStopwatch.stop();
        final encSize = await File(sendFilePath).length();
        final priorSize = await File(
          encPath.replaceAll('.enc', ''),
        ).length().catchError((_) => encSize);
        final encSpeed = stepStopwatch.elapsed.inMilliseconds > 0
            ? (priorSize / (stepStopwatch.elapsed.inMilliseconds / 1000))
            : 0.0;
        print('  Encrypted: ${TransferProgress.formatSize(encSize)} '
            '(${stepStopwatch.elapsed.inMilliseconds}ms, '
            '${TransferProgress.formatSize(encSpeed.toInt())}/s)');
      }

      // SHA-256 is computed incrementally inside TcpSender.sendFile()
      // during chunk reads — no separate pre-pass over the file.
      // The metadata.sha256 field is intentionally left empty; the
      // receiver only consumes the hash from the TRANSFER_END message.
      const sha256Hex = '';

      final sendFileSize = await File(sendFilePath).length();

      // ── Step 3: Setup port forwarding ──
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
        // ── Step 4: Build metadata ──
        final chunkSize = settings.chunkSize;
        final totalChunks = (sendFileSize / chunkSize).ceil();

        // Build file name for transfer
        String transferFileName;
        if (compressionLabel == 'zip') {
          transferFileName = '${fileMeta.name}.zip';
        } else {
          transferFileName = fileMeta.name;
        }
        if (encryptionLabel != 'none') {
          transferFileName = '$transferFileName.enc';
        }

        final metadata = TransferMetadata(
          fileName: transferFileName,
          originalName: fileMeta.name,
          originalType: isDirectory ? 'directory' : 'file',
          totalSize: sendFileSize,
          chunkSize: chunkSize,
          totalChunks: totalChunks,
          compression: compressionLabel,
          encryption: encryptionLabel,
          sha256: sha256Hex,
          targetPath: targetDir,
          salt: saltForMetadata,
        );

        // ── Step 5: Stream file via TCP ──
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
            stdout.write('\r  ${_renderProgressBar(progress)}');
          },
        );

        // Clear the progress line and print final state
        stdout.write('\r${' ' * 80}\r');
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

  /// Check if a file is already in a compressed format.
  bool _isAlreadyCompressed(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    if (_compressedExtensions.contains(ext)) return true;
    // Handle double extensions like .tar.gz
    final name = p.basename(filePath).toLowerCase();
    if (name.endsWith('.tar.gz') || name.endsWith('.tar.bz2') || name.endsWith('.tar.xz')) {
      return true;
    }
    return false;
  }

  /// Render a visual progress bar with speed and ETA.
  String _renderProgressBar(TransferProgress p) {
    const barWidth = 25;
    final filled = (p.percentage * barWidth).round();
    final empty = barWidth - filled;
    final bar = '\x1B[32m${'█' * filled}\x1B[90m${'░' * empty}\x1B[0m';
    final pct = '${(p.percentage * 100).toStringAsFixed(1)}%'.padLeft(6);
    final sent = TransferProgress.formatSize(p.bytesSent);
    final total = TransferProgress.formatSize(p.bytesTotal);
    final speed = p.speedStr;
    final eta = p.eta.inSeconds > 0 ? 'ETA ${p.eta.inSeconds}s' : '';
    return '$bar $pct  $sent / $total  $speed  $eta';
  }

  /// XOR encrypt a file to another file.
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
