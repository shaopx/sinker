import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/constants.dart';
import '../protocol/header.dart';
import '../protocol/message.dart';
import '../protocol/handshake.dart';
import '../model/transfer_result.dart';
import 'buffered_socket_reader.dart';
import 'progress.dart';

// Re-export so existing imports of `tcp_sender.dart show LogCallback` continue
// to work without changes.
export 'buffered_socket_reader.dart' show LogCallback;

/// TCP sender - connects to Android receiver and sends data.
///
/// Supports two modes:
/// - [send]: send from memory (small files)
/// - [sendFile]: stream from disk file (large files, no OOM)
class TcpSender {
  final String host;
  final int port;
  final LogCallback? onLog;

  TcpSender({
    this.host = 'localhost',
    this.port = defaultPort,
    this.onLog,
  });

  void _log(String level, String msg) => onLog?.call(level, msg);

  /// Send a file from disk via streaming. No full file loading into memory.
  ///
  /// [filePath] - path to the file to send (e.g., a .zip temp file)
  /// [metadata] - transfer metadata for handshake
  /// [onProgress] - optional progress callback
  Future<TransferResult> sendFile({
    required String filePath,
    required TransferMetadata metadata,
    ProgressCallback? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    BufferedSocketReader? reader;
    RandomAccessFile? raf;

    try {
      // Connect
      _log('INFO', 'Connecting to $host:$port ...');
      socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));
      _log('INFO', 'Connected to ${socket.remoteAddress.address}:${socket.remotePort}');

      reader = BufferedSocketReader(socket, onLog: onLog);

      // 1. Send HELLO
      _log('DEBUG', 'Sending HELLO ...');
      final caps = Capabilities(protocolVersion: protocolVersion);
      socket.add(Handshake.buildHello(caps));
      await socket.flush();

      // 2. Receive HELLO_ACK
      _log('DEBUG', 'Waiting for HELLO_ACK ...');
      await _expectMessage(reader, MessageType.helloAck);
      _log('INFO', 'Handshake complete');

      // 3. Send TRANSFER_START
      _log('DEBUG', 'Sending TRANSFER_START (file=${metadata.originalName}, '
          'size=${metadata.totalSize}, chunks=${metadata.totalChunks}) ...');
      socket.add(Handshake.buildTransferStart(metadata));
      await socket.flush();

      // 4. Receive TRANSFER_ACK
      _log('DEBUG', 'Waiting for TRANSFER_ACK ...');
      final ackPayload = await _expectMessage(reader, MessageType.transferAck);
      final ackJson = json.decode(utf8.decode(ackPayload)) as Map<String, dynamic>;
      if (ackJson['ready'] != true) {
        return TransferResult.failure('Receiver rejected: ${ackJson['reason']}');
      }
      _log('INFO', 'Receiver ready, starting file stream transfer');

      // 5. Stream DATA_CHUNKs from file
      raf = await File(filePath).open(mode: FileMode.read);
      final fileSize = await File(filePath).length();
      final chunkSize = metadata.chunkSize;
      var offset = 0;
      var chunkIndex = 0;

      while (offset < fileSize) {
        final remaining = fileSize - offset;
        final readSize = remaining < chunkSize ? remaining : chunkSize;
        final chunk = await raf.read(readSize);

        socket.add(Handshake.buildDataChunk(
          Uint8List.fromList(chunk),
          sequenceNumber: chunkIndex,
        ));
        await socket.flush();

        offset += chunk.length;
        chunkIndex++;

        if (chunkIndex % 100 == 0 || chunkIndex == metadata.totalChunks) {
          _log('DEBUG', 'Sent chunk $chunkIndex/${metadata.totalChunks} '
              '(${TransferProgress.formatSize(offset)})');
        }

        onProgress?.call(TransferProgress(
          fileName: metadata.originalName,
          chunkIndex: chunkIndex,
          totalChunks: metadata.totalChunks,
          bytesSent: offset,
          bytesTotal: fileSize,
          elapsed: stopwatch.elapsed,
        ));
      }

      _log('INFO', 'All ${metadata.totalChunks} chunks sent');

      // 6. Send TRANSFER_END
      _log('DEBUG', 'Sending TRANSFER_END (sha256=${metadata.sha256.substring(0, 16)}...) ...');
      socket.add(Handshake.buildTransferEnd(metadata.sha256));
      await socket.flush();

      // 7. Receive TRANSFER_COMPLETE
      _log('DEBUG', 'Waiting for TRANSFER_COMPLETE ...');
      final completePayload = await _expectMessage(reader, MessageType.transferComplete);
      final completeJson =
          json.decode(utf8.decode(completePayload)) as Map<String, dynamic>;

      // 8. Send BYE
      socket.add(Handshake.buildBye());
      await socket.flush();

      stopwatch.stop();

      if (completeJson['success'] == true) {
        _log('INFO', 'Transfer successful: ${TransferProgress.formatSize(fileSize)} '
            'in ${stopwatch.elapsed.inSeconds}s');
        return TransferResult.success(
          bytesTransferred: fileSize,
          duration: stopwatch.elapsed,
        );
      } else {
        final msg = completeJson['message'] as String? ?? 'Transfer failed on receiver side';
        _log('ERROR', 'Transfer failed: $msg');
        return TransferResult.failure(msg);
      }
    } on SocketException catch (e) {
      _log('ERROR', 'Socket exception: $e');
      return TransferResult.failure('Connection failed: $e');
    } on TimeoutException catch (e) {
      _log('ERROR', 'Timeout: $e');
      return TransferResult.failure('Connection timeout: $e');
    } catch (e, stackTrace) {
      _log('ERROR', 'Transfer error: $e');
      _log('DEBUG', 'Stack trace:\n$stackTrace');
      return TransferResult.failure('Transfer error: $e');
    } finally {
      _log('DEBUG', 'Closing connection ...');
      await raf?.close();
      reader?.dispose();
      await socket?.close();
      _log('DEBUG', 'Connection closed');
    }
  }

  /// Send data from memory (for small payloads).
  /// For large files, use [sendFile] instead.
  Future<TransferResult> send({
    required Uint8List encryptedData,
    required TransferMetadata metadata,
    ProgressCallback? onProgress,
  }) async {
    // Write to temp file, then stream
    final tempFile = File('${Directory.systemTemp.path}/sinker_send_${DateTime.now().millisecondsSinceEpoch}.tmp');
    try {
      await tempFile.writeAsBytes(encryptedData);
      return await sendFile(
        filePath: tempFile.path,
        metadata: metadata,
        onProgress: onProgress,
      );
    } finally {
      if (tempFile.existsSync()) {
        await tempFile.delete();
      }
    }
  }

  /// Read a complete message (header + payload) from buffered reader.
  Future<Uint8List> _expectMessage(
    BufferedSocketReader reader,
    MessageType expected,
  ) async {
    final headerBytes = await reader.readExact(headerSize);
    final header = PacketHeader.decode(headerBytes);

    _log('DEBUG', 'Received header: ${header.messageType.name}, '
        'payload=${header.payloadLength}B, seq=${header.sequenceNumber}');

    if (header.messageType == MessageType.error) {
      if (header.payloadLength > 0) {
        final errorPayload = await reader.readExact(header.payloadLength);
        final errorJson = json.decode(utf8.decode(errorPayload)) as Map<String, dynamic>;
        throw StateError('Remote error: ${errorJson['error']}');
      }
      throw StateError('Remote error (no details)');
    }

    if (header.messageType != expected) {
      throw StateError(
        'Protocol error: expected ${expected.name} but got ${header.messageType.name}',
      );
    }

    if (header.payloadLength > 0) {
      return await reader.readExact(header.payloadLength);
    }
    return Uint8List(0);
  }
}

