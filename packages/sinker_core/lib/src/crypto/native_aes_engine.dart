import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;

import '../protocol/constants.dart';
import 'crypto_engine.dart';

/// AES-256-GCM engine using platform-native crypto (via `package:cryptography`).
///
/// Uses hardware AES-NI on x86 or ARM crypto extensions — typically
/// 200-4000 MB/s depending on platform, vs ~2 MB/s for pure Dart pointycastle.
///
/// Encrypted output format is identical to [AesEngine]:
///   `IV(12 bytes) + ciphertext + GCM_tag(16 bytes)`
///
/// This means a file encrypted with NativeAesEngine can be decrypted by
/// AesEngine and vice versa.
class NativeAesEngine implements CryptoEngine {
  final Uint8List key;
  final crypto.AesGcm _algorithm;

  NativeAesEngine({required this.key})
      : _algorithm = crypto.AesGcm.with256bits() {
    if (key.length != aesKeyLength) {
      throw ArgumentError('Key must be $aesKeyLength bytes, got ${key.length}');
    }
  }

  @override
  String get modeName => 'aes-256-gcm';

  /// Encrypt plaintext. Returns `IV(12) + ciphertext + tag(16)`.
  ///
  /// Note: This wraps an async API synchronously — for large data,
  /// prefer [encryptAsync].
  @override
  Uint8List encrypt(Uint8List plaintext) {
    // CryptoEngine interface is sync, but cryptography package is async.
    // We can't make the interface async without breaking changes.
    // Throw to guide callers to use encryptAsync instead.
    throw UnsupportedError(
      'NativeAesEngine requires async API. Use encryptAsync() instead.',
    );
  }

  @override
  Uint8List decrypt(Uint8List ciphertext) {
    throw UnsupportedError(
      'NativeAesEngine requires async API. Use decryptAsync() instead.',
    );
  }

  /// Async encrypt. Returns `IV(12) + ciphertext + tag(16)`.
  Future<Uint8List> encryptAsync(Uint8List plaintext) async {
    final secretKey = crypto.SecretKey(key);
    final secretBox = await _algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
    );

    // Serialize to same format as AesEngine: IV + ciphertext + tag
    final nonce = secretBox.nonce;
    final cipherText = secretBox.cipherText;
    final mac = secretBox.mac.bytes;

    final result = Uint8List(nonce.length + cipherText.length + mac.length);
    result.setRange(0, nonce.length, nonce);
    result.setRange(nonce.length, nonce.length + cipherText.length, cipherText);
    result.setRange(nonce.length + cipherText.length, result.length, mac);
    return result;
  }

  /// Async decrypt. Input: `IV(12) + ciphertext + tag(16)`.
  Future<Uint8List> decryptAsync(Uint8List data) async {
    if (data.length < gcmIvLength + gcmTagLength) {
      throw FormatException('Encrypted data too short: ${data.length} bytes');
    }

    final nonce = data.sublist(0, gcmIvLength);
    final cipherText = data.sublist(gcmIvLength, data.length - gcmTagLength);
    final mac = crypto.Mac(data.sublist(data.length - gcmTagLength));

    final secretBox = crypto.SecretBox(
      cipherText,
      nonce: nonce,
      mac: mac,
    );

    final secretKey = crypto.SecretKey(key);
    final plaintext = await _algorithm.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    return Uint8List.fromList(plaintext);
  }
}
