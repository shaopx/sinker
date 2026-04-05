import 'dart:typed_data';

/// Encryption mode.
enum CryptoMode {
  /// No encryption, raw data pass-through. Fastest.
  none,

  /// XOR obfuscation with key-derived stream. Very fast (~GB/s).
  /// Sufficient to prevent casual inspection and monitoring tools.
  xor,

  /// AES-256-GCM. Strong encryption but slow in pure Dart (~2 MB/s).
  /// Use only for small sensitive files.
  aes,
}

/// Common interface for all crypto engines.
abstract class CryptoEngine {
  /// Encrypt/obfuscate data.
  Uint8List encrypt(Uint8List plaintext);

  /// Decrypt/de-obfuscate data.
  Uint8List decrypt(Uint8List ciphertext);

  /// The mode name (for protocol metadata).
  String get modeName;
}

/// No-op engine, passes data through unchanged.
class NoCryptoEngine implements CryptoEngine {
  @override
  String get modeName => 'none';

  @override
  Uint8List encrypt(Uint8List plaintext) => plaintext;

  @override
  Uint8List decrypt(Uint8List ciphertext) => ciphertext;
}

/// Factory to create CryptoEngine by mode.
class CryptoEngineFactory {
  /// Create engine from mode and key.
  ///
  /// Import [AesEngine] and [XorEngine] separately since they
  /// have different dependencies.
  static CryptoEngine create(CryptoMode mode, Uint8List key) {
    // We can't import AesEngine/XorEngine here to avoid circular deps.
    // Use this as a convenience only from app layer.
    throw UnimplementedError(
      'Use createFromModeName() or construct engines directly',
    );
  }

  /// Parse mode string from protocol metadata.
  static CryptoMode parseMode(String modeName) {
    switch (modeName) {
      case 'none':
        return CryptoMode.none;
      case 'xor':
        return CryptoMode.xor;
      case 'aes-256-gcm':
        return CryptoMode.aes;
      default:
        throw ArgumentError('Unknown crypto mode: $modeName');
    }
  }
}
