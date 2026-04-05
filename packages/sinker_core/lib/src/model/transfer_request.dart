import '../protocol/constants.dart';

/// Configuration for a transfer operation.
class TransferRequest {
  final String sourcePath;
  final String targetDir;
  final String password;
  final String? deviceSerial;
  final int localPort;
  final int remotePort;
  final int chunkSize;

  const TransferRequest({
    required this.sourcePath,
    this.targetDir = defaultTargetDir,
    this.password = defaultPassword,
    this.deviceSerial,
    this.localPort = defaultPort,
    this.remotePort = defaultPort,
    this.chunkSize = defaultChunkSize,
  });
}
