import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../protocol/constants.dart';
import 'crypto_engine.dart';

/// AES-256-GCM encryption/decryption engine.
///
/// Strong encryption but slow in pure Dart (~2 MB/s).
/// Use [XorEngine] for large files where speed matters more than
/// cryptographic security.
///
/// Encrypted output format: `IV(12 bytes) + ciphertext + GCM_tag(16 bytes)`
class AesEngine implements CryptoEngine {
  final Uint8List key;

  AesEngine({required this.key}) {
    if (key.length != aesKeyLength) {
      throw ArgumentError('Key must be $aesKeyLength bytes, got ${key.length}');
    }
  }

  @override
  String get modeName => 'aes-256-gcm';

  /// Encrypt plaintext. Returns `IV + ciphertext + tag`.
  @override
  Uint8List encrypt(Uint8List plaintext) {
    final iv = _generateIv();
    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(key),
      gcmTagLength * 8, // tag length in bits
      iv,
      Uint8List(0), // no additional authenticated data
    );

    cipher.init(true, params);
    final ciphertext = Uint8List(cipher.getOutputSize(plaintext.length));
    final len = cipher.processBytes(plaintext, 0, plaintext.length, ciphertext, 0);
    cipher.doFinal(ciphertext, len);

    // Output: IV + ciphertext (includes GCM tag appended by pointycastle)
    final result = Uint8List(gcmIvLength + ciphertext.length);
    result.setRange(0, gcmIvLength, iv);
    result.setRange(gcmIvLength, result.length, ciphertext);
    return result;
  }

  /// Decrypt data produced by [encrypt]. Input: `IV + ciphertext + tag`.
  @override
  Uint8List decrypt(Uint8List data) {
    if (data.length < gcmIvLength + gcmTagLength) {
      throw FormatException(
        'Encrypted data too short: ${data.length} bytes',
      );
    }

    final iv = data.sublist(0, gcmIvLength);
    final ciphertextWithTag = data.sublist(gcmIvLength);

    final cipher = GCMBlockCipher(AESEngine());
    final params = AEADParameters(
      KeyParameter(key),
      gcmTagLength * 8,
      iv,
      Uint8List(0),
    );

    cipher.init(false, params);
    final plaintext = Uint8List(cipher.getOutputSize(ciphertextWithTag.length));
    final len = cipher.processBytes(
      ciphertextWithTag, 0, ciphertextWithTag.length, plaintext, 0,
    );
    cipher.doFinal(plaintext, len);

    return plaintext;
  }

  /// Generate a random IV/nonce.
  static Uint8List _generateIv() {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(gcmIvLength, (_) => random.nextInt(256)),
    );
  }
}
