/// Result of a transfer operation.
class TransferResult {
  final bool success;
  final String? errorMessage;
  final int bytesTransferred;
  final Duration duration;

  const TransferResult._({
    required this.success,
    this.errorMessage,
    this.bytesTransferred = 0,
    this.duration = Duration.zero,
  });

  factory TransferResult.success({
    required int bytesTransferred,
    required Duration duration,
  }) =>
      TransferResult._(
        success: true,
        bytesTransferred: bytesTransferred,
        duration: duration,
      );

  factory TransferResult.failure(String message) => TransferResult._(
        success: false,
        errorMessage: message,
      );

  /// Average speed in bytes per second.
  double get speed =>
      duration.inMilliseconds > 0
          ? bytesTransferred / (duration.inMilliseconds / 1000)
          : 0.0;

  @override
  String toString() {
    if (success) {
      return 'TransferResult(OK, $bytesTransferred bytes in ${duration.inSeconds}s)';
    }
    return 'TransferResult(FAILED: $errorMessage)';
  }
}
