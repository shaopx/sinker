import 'dart:typed_data';

import 'constants.dart';
import 'message.dart';

/// 14-byte binary packet header for Sinker protocol.
///
/// Layout (big-endian):
/// ```
/// Offset  Size  Field
/// 0       4     magic (0x534E4B52 = "SNKR")
/// 4       1     version
/// 5       1     message_type
/// 6       4     payload_length
/// 10      2     sequence_number
/// 12      2     checksum (CRC-16 of bytes 0..11)
/// ```
class PacketHeader {
  final int version;
  final MessageType messageType;
  final int payloadLength;
  final int sequenceNumber;

  const PacketHeader({
    this.version = protocolVersion,
    required this.messageType,
    required this.payloadLength,
    this.sequenceNumber = 0,
  });

  /// Encode header to 14 bytes.
  Uint8List encode() {
    final data = ByteData(headerSize);

    // Magic
    data.setUint32(0, protocolMagic);
    // Version
    data.setUint8(4, version);
    // Message type
    data.setUint8(5, messageType.value);
    // Payload length
    data.setUint32(6, payloadLength);
    // Sequence number
    data.setUint16(10, sequenceNumber);
    // Checksum (CRC-16 of first 12 bytes)
    final checksum = _computeCrc16(data.buffer.asUint8List(), 12);
    data.setUint16(12, checksum);

    return data.buffer.asUint8List();
  }

  /// Decode header from 14 bytes. Throws [FormatException] on invalid data.
  factory PacketHeader.decode(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw FormatException('Header too short: ${bytes.length} bytes, need $headerSize');
    }

    final data = ByteData.sublistView(bytes, 0, headerSize);

    // Verify magic
    final magic = data.getUint32(0);
    if (magic != protocolMagic) {
      throw FormatException(
        'Invalid magic: 0x${magic.toRadixString(16)}, expected 0x${protocolMagic.toRadixString(16)}',
      );
    }

    // Verify checksum
    final storedChecksum = data.getUint16(12);
    final computedChecksum = _computeCrc16(bytes, 12);
    if (storedChecksum != computedChecksum) {
      throw FormatException(
        'Checksum mismatch: stored=0x${storedChecksum.toRadixString(16)}, '
        'computed=0x${computedChecksum.toRadixString(16)}',
      );
    }

    final payloadLength = data.getUint32(6);
    if (payloadLength > maxPayloadSize) {
      throw FormatException(
        'Payload too large: $payloadLength bytes, max $maxPayloadSize',
      );
    }

    return PacketHeader(
      version: data.getUint8(4),
      messageType: MessageType.fromValue(data.getUint8(5)),
      payloadLength: payloadLength,
      sequenceNumber: data.getUint16(10),
    );
  }

  /// CRC-16/CCITT-FALSE
  static int _computeCrc16(Uint8List data, int length) {
    var crc = 0xFFFF;
    for (var i = 0; i < length; i++) {
      crc ^= (data[i] << 8);
      for (var j = 0; j < 8; j++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc;
  }

  @override
  String toString() =>
      'PacketHeader(v$version, ${messageType.name}, ${payloadLength}B, seq=$sequenceNumber)';
}
