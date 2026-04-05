/// Transfer progress tracking.

/// Callback type for progress updates.
typedef ProgressCallback = void Function(TransferProgress progress);

/// Represents the current state of a transfer.
class TransferProgress {
  final String fileName;
  final int chunkIndex;
  final int totalChunks;
  final int bytesSent;
  final int bytesTotal;
  final Duration elapsed;

  const TransferProgress({
    required this.fileName,
    required this.chunkIndex,
    required this.totalChunks,
    required this.bytesSent,
    required this.bytesTotal,
    required this.elapsed,
  });

  /// Progress percentage (0.0 - 1.0).
  double get percentage =>
      bytesTotal > 0 ? (bytesSent / bytesTotal).clamp(0.0, 1.0) : 0.0;

  /// Transfer speed in bytes per second.
  double get speed =>
      elapsed.inMilliseconds > 0 ? bytesSent / (elapsed.inMilliseconds / 1000) : 0.0;

  /// Estimated time remaining.
  Duration get eta {
    if (speed <= 0 || bytesSent >= bytesTotal) return Duration.zero;
    final remaining = (bytesTotal - bytesSent) / speed;
    return Duration(seconds: remaining.ceil());
  }

  /// Human-readable speed string.
  String get speedStr {
    if (speed < 1024) return '${speed.toStringAsFixed(0)} B/s';
    if (speed < 1024 * 1024) return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    return '${(speed / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  /// Human-readable size string.
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  String toString() =>
      '[$chunkIndex/$totalChunks] ${formatSize(bytesSent)}/${formatSize(bytesTotal)} '
      '(${(percentage * 100).toStringAsFixed(1)}%) $speedStr';
}
