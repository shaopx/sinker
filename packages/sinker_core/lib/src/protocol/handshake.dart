import 'dart:convert';
import 'dart:typed_data';

import 'header.dart';
import 'message.dart';
import 'constants.dart';

/// Builds and parses handshake messages.
class Handshake {
  /// Build a HELLO message with capabilities.
  static Uint8List buildHello(Capabilities caps) {
    return _buildMessage(MessageType.hello, caps.toJson());
  }

  /// Build a HELLO_ACK message with capabilities.
  static Uint8List buildHelloAck(Capabilities caps) {
    return _buildMessage(MessageType.helloAck, caps.toJson());
  }

  /// Build a TRANSFER_START message with metadata.
  static Uint8List buildTransferStart(TransferMetadata metadata) {
    return _buildMessage(MessageType.transferStart, metadata.toJson());
  }

  /// Build a TRANSFER_ACK message.
  static Uint8List buildTransferAck({required bool ready, String? reason}) {
    return _buildMessage(MessageType.transferAck, {
      'ready': ready,
      if (reason != null) 'reason': reason,
    });
  }

  /// Build a DATA_CHUNK message.
  static Uint8List buildDataChunk(Uint8List data, {int sequenceNumber = 0}) {
    final header = PacketHeader(
      messageType: MessageType.dataChunk,
      payloadLength: data.length,
      sequenceNumber: sequenceNumber,
    );
    final headerBytes = header.encode();
    final result = Uint8List(headerSize + data.length);
    result.setRange(0, headerSize, headerBytes);
    result.setRange(headerSize, result.length, data);
    return result;
  }

  /// Build a TRANSFER_END message with SHA-256 checksum.
  static Uint8List buildTransferEnd(String sha256Hex) {
    return _buildMessage(MessageType.transferEnd, {'sha256': sha256Hex});
  }

  /// Build a TRANSFER_COMPLETE message.
  static Uint8List buildTransferComplete({required bool success, String? message}) {
    return _buildMessage(MessageType.transferComplete, {
      'success': success,
      if (message != null) 'message': message,
    });
  }

  /// Build an ERROR message.
  static Uint8List buildError(String errorMessage) {
    return _buildMessage(MessageType.error, {'error': errorMessage});
  }

  /// Build a BYE message.
  static Uint8List buildBye() {
    final header = PacketHeader(
      messageType: MessageType.bye,
      payloadLength: 0,
    );
    return header.encode();
  }

  /// Parse a JSON payload from a message.
  static Map<String, dynamic> parseJsonPayload(Uint8List payload) {
    final jsonStr = utf8.decode(payload);
    return json.decode(jsonStr) as Map<String, dynamic>;
  }

  static Uint8List _buildMessage(MessageType type, Map<String, dynamic> payload) {
    final jsonBytes = utf8.encode(json.encode(payload));
    final header = PacketHeader(
      messageType: type,
      payloadLength: jsonBytes.length,
    );
    final headerBytes = header.encode();
    final result = Uint8List(headerSize + jsonBytes.length);
    result.setRange(0, headerSize, headerBytes);
    result.setRange(headerSize, result.length, jsonBytes);
    return result;
  }
}
