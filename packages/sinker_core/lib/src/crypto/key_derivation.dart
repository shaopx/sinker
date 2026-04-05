import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_pkg;
import 'package:pointycastle/pointycastle.dart';

import '../protocol/constants.dart';

/// PBKDF2 key derivation and salt generation.
class KeyDerivation {
  /// Derive a 256-bit key from password and salt using PBKDF2-HMAC-SHA256.
  static Uint8List deriveKey({
    required String password,
    required Uint8List salt,
    int iterations = pbkdf2Iterations,
    int keyLength = aesKeyLength,
  }) {
    final pbkdf2 = KeyDerivator('SHA-256/HMAC/PBKDF2');
    final params = Pbkdf2Parameters(salt, iterations, keyLength);
    pbkdf2.init(params);

    final passwordBytes = Uint8List.fromList(password.codeUnits);
    return pbkdf2.process(passwordBytes);
  }

  /// Generate a random salt.
  static Uint8List generateSalt([int length = saltLength]) {
    final random = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// Compute SHA-256 hash of data, return hex string.
  static String sha256Hex(Uint8List data) {
    return crypto_pkg.sha256.convert(data).toString();
  }

  /// Compute SHA-256 of a file by path (streaming, no full load).
  static Future<String> sha256File(String filePath) async {
    final file = File(filePath);
    final digest = await crypto_pkg.sha256.bind(file.openRead()).last;
    return digest.toString();
  }
}
