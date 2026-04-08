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

  /// Current process RSS (resident set size) in MB, for memory diagnostics.
  String _rss() {
    try {
      final mb = ProcessInfo.currentRss / 1024 / 1024;
      return '${mb.toStringAsFixed(0)}MB';
    } catch (_) {
      return 'n/a';
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }

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
    final tempSize = await File(tempFilePath).length();
    _log('INFO', '═══ Processing: ${metadata.originalName} ═══');
    _log('INFO', 'meta: encryption=${metadata.encryption}, '
        'compression=${metadata.compression}, '
        'origType=${metadata.originalType}, '
        'declared=${_fmtSize(metadata.totalSize)}');
    _log('INFO', 'tempFile=$tempFilePath actualSize=${_fmtSize(tempSize)} '
        'rss=${_rss()}');
    onStatusChanged?.call('Processing: ${metadata.originalName}');

    try {
      // ── Step 1: Decrypt if needed ──
      String dataFilePath;

      if (metadata.encryption == 'none') {
        dataFilePath = tempFilePath;
        _log('DEBUG', 'Step1: no decryption needed, rss=${_rss()}');
      } else {
        _log('INFO', 'Step1: decrypting (${metadata.encryption}) rss=${_rss()}');
        onStatusChanged?.call('Decrypting...');
        final stopwatch = Stopwatch()..start();

        final salt = base64.decode(metadata.salt);
        final key = KeyDerivation.deriveKey(
          password: password,
          salt: Uint8List.fromList(salt),
        );

        final decryptedPath = '$tempFilePath.dec';

        if (metadata.encryption == 'xor') {
          _log('WARN', 'XOR loads entire file into memory! '
              'size=${_fmtSize(tempSize)} rss=${_rss()}');
          final encData = await File(tempFilePath).readAsBytes();
          _log('DEBUG', 'XOR: file loaded, rss=${_rss()}');
          final engine = XorEngine(key: key);
          final decData = engine.decrypt(encData);
          await File(decryptedPath).writeAsBytes(decData);
        } else if (metadata.encryption == 'aes-256-gcm') {
          // File-based chunked decryption — no OOM for any file size
          _log('DEBUG', 'AES chunked decrypt starting, rss=${_rss()}');
          final engine = NativeAesEngine(key: key);
          await engine.decryptFileAsync(tempFilePath, decryptedPath);
          _log('DEBUG', 'AES chunked decrypt done, rss=${_rss()}');
        } else {
          throw UnsupportedError('Unknown encryption: ${metadata.encryption}');
        }

        stopwatch.stop();
        final decSize = await File(decryptedPath).length();
        _log('INFO', 'Decrypted in ${stopwatch.elapsed.inMilliseconds}ms, '
            'outSize=${_fmtSize(decSize)} rss=${_rss()}');

        // Clean up encrypted temp file
        try { await File(tempFilePath).delete(); } catch (_) {}

        dataFilePath = decryptedPath;
      }

      // ── Step 2: Save the file directly to target ──
      // We NEVER extract on Android — extraction loads file contents into
      // memory and OOMs on multi-GB archives. The .zip is a STORED-mode
      // (no compression) container; the user can open it with any file
      // manager on Android, or it's the original file as-is.
      final stopwatch = Stopwatch()..start();

      // Decide the final filename:
      //   - file source + no compression → originalName
      //   - directory source + zip       → originalName.zip
      //   - file source + zip            → originalName.zip
      String targetName;
      if (metadata.compression == 'zip') {
        targetName = metadata.originalName.toLowerCase().endsWith('.zip')
            ? metadata.originalName
            : '${metadata.originalName}.zip';
      } else {
        targetName = metadata.originalName;
      }
      final targetPath = '$saveDir/$targetName';

      _log('INFO', 'Step2: saving to $targetPath rss=${_rss()}');
      onStatusChanged?.call('Saving...');

      await Directory(saveDir).create(recursive: true);

      // Move or copy the file to its final destination (no extraction!)
      try {
        await File(dataFilePath).rename(targetPath);
        _log('DEBUG', 'rename succeeded (same filesystem)');
      } catch (e) {
        _log('WARN', 'rename failed ($e), falling back to copy');
        await File(dataFilePath).copy(targetPath);
        await File(dataFilePath).delete();
        _log('DEBUG', 'copy fallback complete');
      }

      stopwatch.stop();
      _log('INFO', 'Saved in ${stopwatch.elapsed.inMilliseconds}ms '
          'rss=${_rss()}');

      // Clean up any leftover intermediate files
      try {
        if (dataFilePath != tempFilePath) {
          final f = File(dataFilePath);
          if (await f.exists()) await f.delete();
        }
        final tempF = File(tempFilePath);
        if (await tempF.exists()) await tempF.delete();
      } catch (_) {}

      final savedTo = targetPath;
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
