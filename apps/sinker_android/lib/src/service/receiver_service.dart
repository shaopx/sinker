import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sinker_core/sinker_core.dart';

/// Orchestrates the file receiving process:
/// TCP listen → receive to temp file → decrypt (if needed) → decompress → save.
class ReceiverService {
  final int port;
  final String password;
  final String saveDir;

  TcpReceiver? _receiver;
  bool _running = false;

  /// Callback for status updates.
  void Function(String message)? onStatusChanged;

  /// Callback for progress updates.
  ProgressCallback? onProgress;

  /// Callback when a transfer completes.
  void Function(String fileName, bool success)? onTransferComplete;

  /// Callback for detailed logs.
  void Function(String level, String message)? onLog;

  ReceiverService({
    this.port = defaultPort,
    this.password = defaultPassword,
    required this.saveDir,
  });

  bool get isRunning => _running;

  void _log(String level, String msg) => onLog?.call(level, msg);

  /// Start the receiver service.
  Future<void> start() async {
    if (_running) return;

    _log('INFO', 'Starting receiver on port $port, saveDir=$saveDir');
    _receiver = TcpReceiver(
      port: port,
      tempDir: saveDir, // use save dir for temp files too
      onLog: (level, msg) => _log(level, msg),
    );
    _running = true;
    onStatusChanged?.call('Listening on port $port...');

    await _receiver!.startListening(
      onTransfer: _handleTransfer,
      onProgress: onProgress,
    );
  }

  /// Stop the receiver service.
  Future<void> stop() async {
    _log('INFO', 'Stopping receiver');
    _running = false;
    await _receiver?.stopListening();
    _receiver = null;
    onStatusChanged?.call('Stopped');
  }

  /// Handle an incoming transfer.
  /// [tempFilePath] is the temp file with received data on disk.
  Future<void> _handleTransfer(
    TransferMetadata metadata,
    String tempFilePath,
  ) async {
    _log('INFO', 'Processing: ${metadata.originalName} '
        '(encryption=${metadata.encryption})');
    onStatusChanged?.call('Processing: ${metadata.originalName}');

    try {
      String zipFilePath;

      if (metadata.encryption == 'none') {
        // No decryption needed — temp file IS the zip
        zipFilePath = tempFilePath;
        _log('DEBUG', 'No decryption needed');
      } else {
        // Decrypt to a new temp file
        _log('INFO', 'Decrypting (${metadata.encryption})...');
        onStatusChanged?.call('Decrypting...');
        final stopwatch = Stopwatch()..start();

        final salt = base64.decode(metadata.salt);
        final key = KeyDerivation.deriveKey(
          password: password,
          salt: Uint8List.fromList(salt),
        );

        zipFilePath = '$tempFilePath.zip';

        if (metadata.encryption == 'xor') {
          final encData = await File(tempFilePath).readAsBytes();
          final engine = XorEngine(key: key);
          final zipData = engine.decrypt(encData);
          await File(zipFilePath).writeAsBytes(zipData);
        } else if (metadata.encryption == 'aes-256-gcm') {
          // Use platform-native AES for much faster decryption
          final encData = await File(tempFilePath).readAsBytes();
          final engine = NativeAesEngine(key: key);
          final zipData = await engine.decryptAsync(encData);
          await File(zipFilePath).writeAsBytes(zipData);
        } else {
          throw UnsupportedError('Unknown encryption: ${metadata.encryption}');
        }

        stopwatch.stop();
        _log('INFO', 'Decrypted in ${stopwatch.elapsed.inMilliseconds}ms');

        // Clean up encrypted temp file
        try { await File(tempFilePath).delete(); } catch (_) {}
      }

      // Extract zip to target directory
      _log('INFO', 'Extracting to $saveDir/${metadata.originalName} ...');
      onStatusChanged?.call('Extracting...');
      final stopwatch = Stopwatch()..start();
      final targetDir = '$saveDir/${metadata.originalName}';

      if (metadata.originalType == 'file') {
        // For single file, extract zip contents to saveDir directly
        await ZipEngine.extractFile(zipFilePath, saveDir);
      } else {
        await ZipEngine.extractFile(zipFilePath, targetDir);
      }

      stopwatch.stop();
      _log('INFO', 'Extracted in ${stopwatch.elapsed.inMilliseconds}ms');

      // Clean up zip temp file
      try {
        if (zipFilePath != tempFilePath) {
          await File(zipFilePath).delete();
        }
        // Always try to clean temp
        final tempF = File(tempFilePath);
        if (await tempF.exists()) await tempF.delete();
      } catch (_) {}

      final savedTo = metadata.originalType == 'file' ? saveDir : targetDir;
      _log('INFO', 'Saved to: $savedTo');
      onStatusChanged?.call('Saved to: $savedTo');
      onTransferComplete?.call(metadata.originalName, true);
    } catch (e, stackTrace) {
      _log('ERROR', 'Processing failed: $e');
      _log('DEBUG', 'Stack trace:\n$stackTrace');
      onStatusChanged?.call('Error: $e');
      onTransferComplete?.call(metadata.originalName, false);

      // Clean up on error
      try { await File(tempFilePath).delete(); } catch (_) {}
    }
  }
}
