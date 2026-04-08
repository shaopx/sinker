import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/constants.dart';
import '../protocol/header.dart';
import '../protocol/message.dart';
import '../protocol/handshake.dart';
import '../crypto/key_derivation.dart';
import 'progress.dart';
import 'tcp_sender.dart' show LogCallback;

/// Handler called when a transfer is received.
/// [metadata] - transfer metadata
/// [tempFilePath] - path to temp file containing received data
typedef TransferHandler = Future<void> Function(
  TransferMetadata metadata,
  String tempFilePath,
);

/// TCP receiver - listens for incoming connections from PC sender.
///
/// Writes received data chunks directly to a temp file on disk,
/// avoiding out-of-memory errors for large transfers.
class TcpReceiver {
  final int port;
  final String? tempDir;
  final LogCallback? onLog;
  ServerSocket? _server;
  bool _listening = false;

  TcpReceiver({
    this.port = defaultPort,
    this.tempDir,
    this.onLog,
  });

  bool get isListening => _listening;

  void _log(String level, String msg) => onLog?.call(level, msg);

  /// Current process RSS in MB string for memory diagnostics.
  static String _rss() {
    try {
      final mb = ProcessInfo.currentRss / 1024 / 1024;
      return '${mb.toStringAsFixed(0)}MB';
    } catch (_) {
      return 'n/a';
    }
  }

  static String _fmtSize(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }

  /// Start listening for incoming connections.
  Future<void> startListening({
    required TransferHandler onTransfer,
    ProgressCallback? onProgress,
  }) async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _listening = true;
    _log('INFO', 'Listening on port $port');

    await for (final socket in _server!) {
      _log('INFO', 'New connection from ${socket.remoteAddress.address}:${socket.remotePort}');
      try {
        await _handleConnection(socket, onTransfer, onProgress);
      } catch (e, stackTrace) {
        _log('ERROR', 'Connection error: $e');
        _log('DEBUG', 'Stack trace:\n$stackTrace');
        try {
          socket.add(Handshake.buildError(e.toString()));
          await socket.flush();
        } catch (_) {}
      } finally {
        await socket.close();
        _log('DEBUG', 'Connection closed');
      }
    }
  }

  /// Stop listening.
  Future<void> stopListening() async {
    _log('INFO', 'Stopping listener');
    _listening = false;
    await _server?.close();
    _server = null;
  }

  Future<void> _handleConnection(
    Socket socket,
    TransferHandler onTransfer,
    ProgressCallback? onProgress,
  ) async {
    final reader = _BufferedSocketReader(socket, onLog: onLog);
    String? tempFilePath;
    _log('INFO', 'Connection start, rss=${_rss()}');

    try {
      // 1. Receive HELLO
      _log('DEBUG', 'Waiting for HELLO ...');
      final helloHeader = await _readHeader(reader);
      _expectType(helloHeader, MessageType.hello);
      if (helloHeader.payloadLength > 0) {
        await reader.readExact(helloHeader.payloadLength);
      }
      _log('INFO', 'HELLO received');

      // 2. Send HELLO_ACK
      final caps = Capabilities(protocolVersion: protocolVersion);
      socket.add(Handshake.buildHelloAck(caps));
      await socket.flush();

      // 3. Receive TRANSFER_START
      _log('DEBUG', 'Waiting for TRANSFER_START ...');
      final startHeader = await _readHeader(reader);
      _expectType(startHeader, MessageType.transferStart);
      final startPayload = await reader.readExact(startHeader.payloadLength);
      final metadataJson =
          json.decode(utf8.decode(startPayload)) as Map<String, dynamic>;
      final metadata = TransferMetadata.fromJson(metadataJson);
      _log('INFO', 'TRANSFER_START: file=${metadata.originalName}, '
          'size=${TransferProgress.formatSize(metadata.totalSize)}, '
          'chunks=${metadata.totalChunks}, rss=${_rss()}');

      // 4. Send TRANSFER_ACK
      socket.add(Handshake.buildTransferAck(ready: true));
      await socket.flush();

      // 5. Receive DATA_CHUNKs → write directly to temp file
      final tmpDir = tempDir ?? Directory.systemTemp.path;
      tempFilePath = '$tmpDir/sinker_recv_${DateTime.now().millisecondsSinceEpoch}.tmp';
      _log('DEBUG', 'Writing chunks to temp file: $tempFilePath');

      final tempFile = File(tempFilePath);
      final sink = tempFile.openWrite();
      final stopwatch = Stopwatch()..start();
      var bytesReceived = 0;
      var lastLogMs = 0;

      try {
        for (var i = 0; i < metadata.totalChunks; i++) {
          final chunkHeader = await _readHeader(reader);
          _expectType(chunkHeader, MessageType.dataChunk);
          final chunkData = await reader.readExact(chunkHeader.payloadLength);

          // Write to file, not memory!
          sink.add(chunkData);
          bytesReceived += chunkData.length;

          // Periodic disk flush so the OS can write through and free buffer
          // memory; without this Android may keep gigabytes of dirty pages.
          if ((i + 1) % 256 == 0) {
            await sink.flush();
          }

          // Log every ~1s OR every 500 chunks OR at the end. Includes
          // RSS and the BufferedSocketReader high-water-mark — these
          // are the smoking gun for OOM diagnosis.
          final nowMs = stopwatch.elapsed.inMilliseconds;
          if (nowMs - lastLogMs >= 1000 ||
              (i + 1) % 500 == 0 ||
              i + 1 == metadata.totalChunks) {
            lastLogMs = nowMs;
            _log('DEBUG',
                'chunk ${i + 1}/${metadata.totalChunks} '
                'recv=${_fmtSize(bytesReceived)} '
                'bufNow=${_fmtSize(reader.currentBufferSize)} '
                'bufPeak=${_fmtSize(reader.peakBufferSize)} '
                'rss=${_rss()}');
          }

          onProgress?.call(TransferProgress(
            fileName: metadata.originalName,
            chunkIndex: i + 1,
            totalChunks: metadata.totalChunks,
            bytesSent: bytesReceived,
            bytesTotal: metadata.totalSize,
            elapsed: stopwatch.elapsed,
          ));
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      _log('INFO',
          'All chunks received: ${TransferProgress.formatSize(bytesReceived)}, '
          'bufPeak=${_fmtSize(reader.peakBufferSize)}, '
          'pauseCount=${reader.pauseCount}, '
          'rss=${_rss()}');

      // 6. Receive TRANSFER_END + verify checksum
      final endHeader = await _readHeader(reader);
      _expectType(endHeader, MessageType.transferEnd);
      if (endHeader.payloadLength > 0) {
        final endPayload = await reader.readExact(endHeader.payloadLength);
        final endJson = json.decode(utf8.decode(endPayload)) as Map<String, dynamic>;
        final expectedSha256 = endJson['sha256'] as String;

        // Compute SHA-256 of the temp file (streaming, no full load).
        // For 4GB files this can take 30-90s on slower Android storage.
        final shaWatch = Stopwatch()..start();
        _log('INFO', 'Computing SHA-256 of received file '
            '(${_fmtSize(bytesReceived)}) rss=${_rss()}');
        final actualSha256 = await _fileSha256(tempFilePath);
        shaWatch.stop();
        _log('INFO', 'SHA-256 done in ${shaWatch.elapsed.inMilliseconds}ms '
            'rss=${_rss()}');
        _log('DEBUG', 'Expected: ${expectedSha256.substring(0, 16)}...');
        _log('DEBUG', 'Actual:   ${actualSha256.substring(0, 16)}...');

        if (actualSha256 != expectedSha256) {
          _log('ERROR', 'Checksum mismatch!');
          socket.add(Handshake.buildTransferComplete(
            success: false,
            message: 'Checksum mismatch',
          ));
          await socket.flush();
          return;
        }
        _log('INFO', 'Checksum verified OK');
      }

      stopwatch.stop();

      // 7. Send TRANSFER_COMPLETE immediately (before processing!)
      socket.add(Handshake.buildTransferComplete(success: true));
      await socket.flush();
      _log('INFO', 'TRANSFER_COMPLETE sent (${stopwatch.elapsed.inSeconds}s)');

      // 8. Receive BYE
      try {
        final byeHeader = await _readHeader(reader);
        _expectType(byeHeader, MessageType.bye);
        _log('DEBUG', 'BYE received');
      } catch (_) {
        _log('DEBUG', 'No BYE received');
      }

      // 9. Process the temp file (extract, etc.)
      _log('INFO', 'Processing received file ...');
      await onTransfer(metadata, tempFilePath);
      _log('INFO', 'Transfer handler completed');

    } finally {
      reader.dispose();
      // Don't delete temp file here - let the handler decide
    }
  }

  /// Compute SHA-256 of a file in streaming fashion (no full file load).
  Future<String> _fileSha256(String filePath) async {
    return KeyDerivation.sha256File(filePath);
  }

  Future<PacketHeader> _readHeader(_BufferedSocketReader reader) async {
    final bytes = await reader.readExact(headerSize);
    return PacketHeader.decode(bytes);
  }

  void _expectType(PacketHeader header, MessageType expected) {
    if (header.messageType != expected) {
      throw StateError(
        'Protocol error: expected ${expected.name} but got ${header.messageType.name}',
      );
    }
  }
}

/// Buffered reader for socket data with backpressure.
///
/// CRITICAL: Without backpressure, the socket's `listen()` callback
/// accumulates incoming data into [_buffer] as fast as the OS delivers it.
/// For a 4GB file at >100MB/s the buffer can grow to multiple gigabytes
/// before the consumer drains it, causing OOM on Android.
///
/// Backpressure strategy: when [_buffer] grows beyond [_highWaterMark],
/// pause the subscription. When it drops below [_lowWaterMark], resume.
/// Also tracks peak buffer size and pause count for diagnostics.
class _BufferedSocketReader {
  // Pause socket reads when buffer exceeds 16MB; resume below 4MB.
  // Plenty of headroom for a single 1MB chunk + protocol overhead.
  static const int _highWaterMark = 16 * 1024 * 1024;
  static const int _lowWaterMark = 4 * 1024 * 1024;

  // Long timeout — for 4GB+ files, the receiver may need minutes to
  // hash and flush before reading the next message.
  static const Duration _readTimeout = Duration(seconds: 900);

  final Socket _socket;
  final LogCallback? onLog;

  final _buffer = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> _subscription;
  bool _done = false;
  bool _paused = false;
  Object? _error;

  // Diagnostics
  int peakBufferSize = 0;
  int pauseCount = 0;

  int get currentBufferSize => _buffer.length;

  _BufferedSocketReader(this._socket, {this.onLog}) {
    _subscription = _socket.listen(
      (data) {
        _buffer.add(data);
        if (_buffer.length > peakBufferSize) {
          peakBufferSize = _buffer.length;
        }
        // Apply backpressure: pause socket if buffer too large
        if (!_paused && _buffer.length >= _highWaterMark) {
          _paused = true;
          pauseCount++;
          _subscription.pause();
          onLog?.call('DEBUG',
              'Backpressure: pausing socket at '
              '${(_buffer.length / 1024 / 1024).toStringAsFixed(1)}MB '
              '(pauseCount=$pauseCount)');
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        onLog?.call('ERROR', 'Socket stream error: $error');
        _error = error;
        _done = true;
      },
      onDone: () {
        onLog?.call('DEBUG', 'Socket stream closed by remote');
        _done = true;
      },
    );
  }

  Future<Uint8List> readExact(int length) async {
    final deadline = DateTime.now().add(_readTimeout);

    while (_buffer.length < length) {
      if (_error != null) throw StateError('Socket error: $_error');
      if (_done && _buffer.length < length) {
        throw StateError('Connection closed: got ${_buffer.length}B, need $length');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
            'Timeout reading $length bytes after ${_readTimeout.inSeconds}s '
            '(got ${_buffer.length})');
      }
      await Future.delayed(const Duration(milliseconds: 5));
    }

    // Take exactly `length` bytes from the front of the buffer.
    // BytesBuilder doesn't support partial take, so we extract all
    // bytes and re-add the remainder. Length grows by at most one
    // chunk's worth (~1MB) thanks to backpressure, so the copy is cheap.
    final allBytes = _buffer.takeBytes(); // clears buffer
    if (allBytes.length > length) {
      _buffer.add(Uint8List.sublistView(allBytes, length));
    }

    // Resume socket if buffer drained below low water mark
    if (_paused && _buffer.length <= _lowWaterMark) {
      _paused = false;
      _subscription.resume();
      onLog?.call('DEBUG',
          'Backpressure: resuming socket at '
          '${(_buffer.length / 1024 / 1024).toStringAsFixed(1)}MB');
    }

    return Uint8List.sublistView(allBytes, 0, length);
  }

  void dispose() {
    _subscription.cancel();
  }
}
