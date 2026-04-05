/// Message types for Sinker binary protocol.

enum MessageType {
  /// Connection establishment (PC → Android)
  hello(0x01),

  /// Connection acknowledgment (Android → PC)
  helloAck(0x02),

  /// Transfer metadata (PC → Android)
  transferStart(0x10),

  /// Transfer readiness (Android → PC)
  transferAck(0x11),

  /// Encrypted data chunk (PC → Android)
  dataChunk(0x20),

  /// Transfer completion with checksum (PC → Android)
  transferEnd(0x30),

  /// Receive confirmation (Android → PC)
  transferComplete(0x31),

  /// Error (bidirectional)
  error(0xFE),

  /// Disconnect (PC → Android)
  bye(0xFF);

  const MessageType(this.value);
  final int value;

  static MessageType fromValue(int value) {
    return MessageType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => throw FormatException('Unknown message type: 0x${value.toRadixString(16)}'),
    );
  }
}

/// Capabilities exchanged during handshake.
class Capabilities {
  final int protocolVersion;
  final List<String> supportedCompressions;
  final List<String> supportedEncryptions;

  const Capabilities({
    required this.protocolVersion,
    this.supportedCompressions = const ['zip'],
    this.supportedEncryptions = const ['aes-256-gcm'],
  });

  Map<String, dynamic> toJson() => {
        'protocol_version': protocolVersion,
        'supported_compressions': supportedCompressions,
        'supported_encryptions': supportedEncryptions,
      };

  factory Capabilities.fromJson(Map<String, dynamic> json) => Capabilities(
        protocolVersion: json['protocol_version'] as int,
        supportedCompressions:
            (json['supported_compressions'] as List?)?.cast<String>() ?? ['zip'],
        supportedEncryptions:
            (json['supported_encryptions'] as List?)?.cast<String>() ?? ['aes-256-gcm'],
      );
}

/// Transfer metadata sent in TRANSFER_START.
class TransferMetadata {
  final String fileName;
  final String originalName;
  final String originalType; // "file" or "directory"
  final int totalSize;
  final int chunkSize;
  final int totalChunks;
  final String compression;
  final String encryption;
  final String sha256;
  final String targetPath;
  final String salt; // base64 encoded

  const TransferMetadata({
    required this.fileName,
    required this.originalName,
    required this.originalType,
    required this.totalSize,
    required this.chunkSize,
    required this.totalChunks,
    required this.compression,
    required this.encryption,
    required this.sha256,
    required this.targetPath,
    required this.salt,
  });

  Map<String, dynamic> toJson() => {
        'file_name': fileName,
        'original_name': originalName,
        'original_type': originalType,
        'total_size': totalSize,
        'chunk_size': chunkSize,
        'total_chunks': totalChunks,
        'compression': compression,
        'encryption': encryption,
        'sha256': sha256,
        'target_path': targetPath,
        'salt': salt,
      };

  factory TransferMetadata.fromJson(Map<String, dynamic> json) => TransferMetadata(
        fileName: json['file_name'] as String,
        originalName: json['original_name'] as String,
        originalType: json['original_type'] as String,
        totalSize: json['total_size'] as int,
        chunkSize: json['chunk_size'] as int,
        totalChunks: json['total_chunks'] as int,
        compression: json['compression'] as String,
        encryption: json['encryption'] as String,
        sha256: json['sha256'] as String,
        targetPath: json['target_path'] as String,
        salt: json['salt'] as String,
      );
}
