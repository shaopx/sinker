/// Sinker core library - protocol, crypto, compression, transport.
library sinker_core;

// Protocol
export 'src/protocol/constants.dart';
export 'src/protocol/header.dart';
export 'src/protocol/message.dart';
export 'src/protocol/handshake.dart';

// Crypto
export 'src/crypto/crypto_engine.dart';
export 'src/crypto/xor_engine.dart';
export 'src/crypto/aes_engine.dart';
export 'src/crypto/native_aes_engine.dart';
export 'src/crypto/key_derivation.dart';

// Compression
export 'src/compression/zip_engine.dart';

// Transport
export 'src/transport/tcp_sender.dart';
export 'src/transport/tcp_receiver.dart';
export 'src/transport/progress.dart';

// Model
export 'src/model/file_metadata.dart';
export 'src/model/transfer_request.dart';
export 'src/model/transfer_result.dart';
