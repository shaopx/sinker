import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;

import '../protocol/constants.dart';
import 'crypto_engine.dart';

/// Magic bytes for chunked encrypted file format.
const _chunkMagic = <int>[0x53, 0x4E, 0x4B, 0x52, 0x41, 0x45, 0x53, 0x01]; // "SNKRAES\x01"

/// Default plaintext block size for chunked encryption: 4 MB.
const _encryptBlockSize = 4 * 1024 * 1024;

/// AES-256-GCM engine using platform-native crypto (via `package:cryptography`).
///
/// Uses hardware AES-NI on x86 or ARM crypto extensions — typically
/// 200-4000 MB/s depending on platform, vs ~2 MB/s for pure Dart pointycastle.
///
/// For large files, use [encryptFileAsync] / [decryptFileAsync] which
/// process in 4 MB blocks to avoid OOM.
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

  @override
  Uint8List encrypt(Uint8List plaintext) {
    throw UnsupportedError(
      'NativeAesEngine requires async API. Use encryptFileAsync() instead.',
    );
  }

  @override
  Uint8List decrypt(Uint8List ciphertext) {
    throw UnsupportedError(
      'NativeAesEngine requires async API. Use decryptFileAsync() instead.',
    );
  }

  /// Encrypt a file in 4 MB blocks. Memory usage ≈ 4 MB regardless of file size.
  ///
  /// Output format:
  /// ```
  /// Magic "SNKRAES\x01" (8 bytes)
  /// block_size: uint32 big-endian (plaintext block size)
  /// For each block:
  ///   enc_len: uint32 big-endian (IV + ciphertext + tag)
  ///   IV(12) + ciphertext + GCM_tag(16)
  /// ```
  Future<void> encryptFileAsync(String inputPath, String outputPath) async {
    final inputFile = File(inputPath);
    final inputSize = await inputFile.length();
    final raf = await inputFile.open(mode: FileMode.read);
    final sink = File(outputPath).openWrite();

    try {
      // Write header
      sink.add(Uint8List.fromList(_chunkMagic));
      sink.add(_uint32Bytes(_encryptBlockSize));

      final secretKey = crypto.SecretKey(key);
      var offset = 0;

      while (offset < inputSize) {
        final remaining = inputSize - offset;
        final blockSize = remaining < _encryptBlockSize ? remaining : _encryptBlockSize;

        // Read one plaintext block
        final plainBlock = await raf.read(blockSize);

        // Encrypt block
        final secretBox = await _algorithm.encrypt(
          plainBlock,
          secretKey: secretKey,
        );

        // Serialize: IV + ciphertext + tag
        final nonce = secretBox.nonce;
        final ct = secretBox.cipherText;
        final mac = secretBox.mac.bytes;
        final encLen = nonce.length + ct.length + mac.length;

        // Write length prefix + encrypted block
        sink.add(_uint32Bytes(encLen));
        sink.add(Uint8List.fromList(nonce));
        sink.add(Uint8List.fromList(ct));
        sink.add(Uint8List.fromList(mac));

        offset += blockSize;
      }

      await sink.flush();
    } finally {
      await sink.close();
      await raf.close();
    }
  }

  /// Decrypt a chunked encrypted file. Memory usage ≈ 4 MB.
  ///
  /// Auto-detects format: if the file starts with "SNKRAES\x01",
  /// uses chunked decryption; otherwise falls back to single-block decryption.
  Future<void> decryptFileAsync(String inputPath, String outputPath) async {
    final raf = await File(inputPath).open(mode: FileMode.read);

    try {
      // Read and check magic header
      final magic = await raf.read(8);
      if (_matchesMagic(magic)) {
        await _decryptChunked(raf, outputPath);
      } else {
        // Legacy single-block format: read entire file, decrypt in memory
        await raf.setPosition(0);
        final allBytes = await File(inputPath).readAsBytes();
        final plaintext = await _decryptSingleBlock(allBytes);
        await File(outputPath).writeAsBytes(plaintext);
      }
    } finally {
      await raf.close();
    }
  }

  /// Chunked decryption — reads block by block from the RandomAccessFile.
  Future<void> _decryptChunked(RandomAccessFile raf, String outputPath) async {
    // Read block_size (uint32 big-endian) — we skip it, just need enc_len per block
    await raf.read(4);

    final sink = File(outputPath).openWrite();
    final secretKey = crypto.SecretKey(key);
    final fileLen = await raf.length();

    try {
      while (await raf.position() < fileLen) {
        // Read encrypted block length
        final lenBytes = await raf.read(4);
        if (lenBytes.length < 4) break;
        final encLen = _readUint32(lenBytes);

        // Read encrypted block
        final encBlock = await raf.read(encLen);
        if (encBlock.length < encLen) {
          throw FormatException(
            'Unexpected EOF: expected $encLen bytes, got ${encBlock.length}',
          );
        }

        // Parse IV + ciphertext + tag
        final nonce = encBlock.sublist(0, gcmIvLength);
        final ct = encBlock.sublist(gcmIvLength, encBlock.length - gcmTagLength);
        final mac = crypto.Mac(encBlock.sublist(encBlock.length - gcmTagLength));

        final secretBox = crypto.SecretBox(ct, nonce: nonce, mac: mac);
        final plainBlock = await _algorithm.decrypt(
          secretBox,
          secretKey: secretKey,
        );

        sink.add(Uint8List.fromList(plainBlock));
      }

      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// Decrypt a single-block AES-GCM message (legacy format).
  Future<Uint8List> _decryptSingleBlock(Uint8List data) async {
    if (data.length < gcmIvLength + gcmTagLength) {
      throw FormatException('Encrypted data too short: ${data.length} bytes');
    }

    final nonce = data.sublist(0, gcmIvLength);
    final ct = data.sublist(gcmIvLength, data.length - gcmTagLength);
    final mac = crypto.Mac(data.sublist(data.length - gcmTagLength));

    final secretBox = crypto.SecretBox(ct, nonce: nonce, mac: mac);
    final secretKey = crypto.SecretKey(key);
    final plaintext = await _algorithm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(plaintext);
  }

  static bool _matchesMagic(List<int> bytes) {
    if (bytes.length < _chunkMagic.length) return false;
    for (var i = 0; i < _chunkMagic.length; i++) {
      if (bytes[i] != _chunkMagic[i]) return false;
    }
    return true;
  }

  static Uint8List _uint32Bytes(int value) {
    return Uint8List(4)
      ..[0] = (value >> 24) & 0xFF
      ..[1] = (value >> 16) & 0xFF
      ..[2] = (value >> 8) & 0xFF
      ..[3] = value & 0xFF;
  }

  static int _readUint32(List<int> bytes) {
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }
}
