/// Protocol constants for Sinker binary protocol.

/// Magic bytes: "SNKR" in ASCII
const int protocolMagic = 0x534E4B52;

/// Current protocol version
const int protocolVersion = 0x01;

/// Header size in bytes
const int headerSize = 14;

/// Default chunk size: 1 MB
const int defaultChunkSize = 1024 * 1024;

/// Maximum payload size: 16 MB
const int maxPayloadSize = 16 * 1024 * 1024;

/// Default TCP port
const int defaultPort = 18900;

/// Default target directory on Android
const String defaultTargetDir = '/sdcard/Download/sinker/';

/// Default encryption password
const String defaultPassword = 'sinker2024';

/// PBKDF2 iteration count
const int pbkdf2Iterations = 100000;

/// Salt length in bytes
const int saltLength = 16;

/// AES key length in bytes (256-bit)
const int aesKeyLength = 32;

/// GCM IV/nonce length in bytes
const int gcmIvLength = 12;

/// GCM auth tag length in bytes
const int gcmTagLength = 16;
