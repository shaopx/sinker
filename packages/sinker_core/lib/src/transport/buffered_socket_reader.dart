import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Log callback type used by transport components.
/// Levels: INFO / DEBUG / WARN / ERROR.
typedef LogCallback = void Function(String level, String message);

/// Buffered reader for socket data with backpressure.
///
/// CRITICAL: Without backpressure, the socket's `listen()` callback
/// accumulates incoming data into the internal buffer as fast as the OS
/// delivers it. For multi-GB transfers at >100MB/s the buffer can grow
/// to gigabytes before the consumer drains it, causing OOM (especially
/// on memory-constrained Android devices).
///
/// Backpressure strategy: when the buffer grows beyond [_highWaterMark],
/// pause the subscription. When it drops below [_lowWaterMark], resume.
/// The TCP receive window then naturally pushes back to the sender.
///
/// Also tracks [peakBufferSize] and [pauseCount] for diagnostics, and
/// uses zero-copy `takeBytes` + `Uint8List.sublistView` so each
/// `readExact` call does not duplicate the buffer.
///
/// Used by both `TcpSender` and `TcpReceiver`.
class BufferedSocketReader {
  /// Pause socket reads when buffer exceeds 16 MB.
  static const int _highWaterMark = 16 * 1024 * 1024;

  /// Resume socket reads when buffer drops below 4 MB.
  static const int _lowWaterMark = 4 * 1024 * 1024;

  /// Long timeout — for multi-GB files, the peer may need many minutes
  /// to compute SHA-256 and flush to disk before sending the next message.
  static const Duration _readTimeout = Duration(seconds: 900);

  final Socket _socket;
  final LogCallback? onLog;

  final _buffer = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> _subscription;
  bool _done = false;
  bool _paused = false;
  Object? _error;

  // Diagnostics — readable from outside for log output.
  int peakBufferSize = 0;
  int pauseCount = 0;

  int get currentBufferSize => _buffer.length;

  BufferedSocketReader(this._socket, {this.onLog}) {
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
          onLog?.call(
            'DEBUG',
            'Backpressure: pausing socket at '
            '${(_buffer.length / 1024 / 1024).toStringAsFixed(1)}MB '
            '(pauseCount=$pauseCount)',
          );
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

  /// Read exactly [length] bytes from the socket. Throws [TimeoutException]
  /// if [_readTimeout] elapses, or [StateError] if the connection closes
  /// before enough bytes arrive.
  Future<Uint8List> readExact(int length) async {
    final deadline = DateTime.now().add(_readTimeout);

    while (_buffer.length < length) {
      if (_error != null) {
        throw StateError('Socket error while reading: $_error');
      }
      if (_done && _buffer.length < length) {
        throw StateError(
          'Connection closed prematurely: got ${_buffer.length} bytes, need $length',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Timeout reading $length bytes after ${_readTimeout.inSeconds}s '
          '(got ${_buffer.length})',
        );
      }
      await Future.delayed(const Duration(milliseconds: 5));
    }

    // Take exactly `length` bytes from the front of the buffer.
    // BytesBuilder doesn't support partial take, so we extract all
    // bytes (zero-copy) and re-add the remainder. Length grows by at
    // most one chunk's worth (~1MB) thanks to backpressure.
    final allBytes = _buffer.takeBytes(); // clears buffer, zero-copy
    if (allBytes.length > length) {
      _buffer.add(Uint8List.sublistView(allBytes, length));
    }

    // Resume socket if buffer drained below low water mark
    if (_paused && _buffer.length <= _lowWaterMark) {
      _paused = false;
      _subscription.resume();
      onLog?.call(
        'DEBUG',
        'Backpressure: resuming socket at '
        '${(_buffer.length / 1024 / 1024).toStringAsFixed(1)}MB',
      );
    }

    return Uint8List.sublistView(allBytes, 0, length);
  }

  void dispose() {
    _subscription.cancel();
  }
}
