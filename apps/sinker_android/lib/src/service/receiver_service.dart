import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sinker_core/sinker_core.dart';

/// Orchestrates the file receiving process:
/// TCP listen → receive to temp file → decrypt (if needed) → decompress (if needed) → save.
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
        '(encryption=${metadata.encryption}, compression=${metadata.compression})');
    onStatusChanged?.call('Processing: ${metadata.originalName}');

    try {
      // ── Step 1: Decrypt if needed ──
      String dataFilePath;

      if (metadata.encryption == 'none') {
        dataFilePath = tempFilePath;
        _log('DEBUG', 'No decryption needed');
      } else {
        _log('INFO', 'Decrypting (${metadata.encryption})...');
        onStatusChanged?.call('Decrypting...');
        final stopwatch = Stopwatch()..start();

        final salt = base64.decode(metadata.salt);
        final key = KeyDerivation.deriveKey(
          password: password,
          salt: Uint8List.fromList(salt),
        );

        final decryptedPath = '$tempFilePath.dec';

        if (metadata.encryption == 'xor') {
          final encData = await File(tempFilePath).readAsBytes();
          final engine = XorEngine(key: key);
          final decData = engine.decrypt(encData);
          await File(decryptedPath).writeAsBytes(decData);
        } else if (metadata.encryption == 'aes-256-gcm') {
          // File-based chunked decryption — no OOM for any file size
          final engine = NativeAesEngine(key: key);
          await engine.decryptFileAsync(tempFilePath, decryptedPath);
        } else {
          throw UnsupportedError('Unknown encryption: ${metadata.encryption}');
        }

        stopwatch.stop();
        _log('INFO', 'Decrypted in ${stopwatch.elapsed.inMilliseconds}ms');

        // Clean up encrypted temp file
        try { await File(tempFilePath).delete(); } catch (_) {}

        dataFilePath = decryptedPath;
      }

      // ── Step 2: Extract or save ──
      final stopwatch = Stopwatch()..start();

      if (metadata.compression == 'zip') {
        // Compressed — extract ZIP
        _log('INFO', 'Extracting to $saveDir/${metadata.originalName} ...');
        onStatusChanged?.call('Extracting...');

        final targetDir = '$saveDir/${metadata.originalName}';

        if (metadata.originalType == 'file') {
          await ZipEngine.extractFile(dataFilePath, saveDir);
        } else {
          await ZipEngine.extractFile(dataFilePath, targetDir);
        }

        stopwatch.stop();
        _log('INFO', 'Extracted in ${stopwatch.elapsed.inMilliseconds}ms');
      } else {
        // Not compressed — save file directly
        _log('INFO', 'Saving file to $saveDir/${metadata.originalName} ...');
        onStatusChanged?.call('Saving...');

        final targetPath = '$saveDir/${metadata.originalName}';
        await Directory(saveDir).create(recursive: true);

        // Move or copy the file to its final destination
        try {
          await File(dataFilePath).rename(targetPath);
        } catch (_) {
          // rename fails across filesystems, fall back to copy
          await File(dataFilePath).copy(targetPath);
          await File(dataFilePath).delete();
        }

        stopwatch.stop();
        _log('INFO', 'Saved in ${stopwatch.elapsed.inMilliseconds}ms');
      }

      // Clean up intermediate files
      try {
        if (dataFilePath != tempFilePath) {
          final f = File(dataFilePath);
          if (await f.exists()) await f.delete();
        }
        final tempF = File(tempFilePath);
        if (await tempF.exists()) await tempF.delete();
      } catch (_) {}

      final savedTo = metadata.compression == 'zip' && metadata.originalType != 'file'
          ? '$saveDir/${metadata.originalName}'
          : saveDir;
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
