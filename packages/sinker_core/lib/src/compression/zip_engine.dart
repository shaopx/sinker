import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// ZIP packaging engine — uses STORED mode (no compression).
///
/// Why STORED instead of DEFLATE:
/// - Sinker transfers over local USB / ADB tunnel, not the internet,
///   so saving a few percent of bytes via DEFLATE costs more CPU time
///   than it saves transfer time.
/// - DEFLATE is single-threaded ~30-80 MB/s; STORED is essentially
///   disk-read speed (hundreds of MB/s).
/// - STORED zips are still 100% valid zip files — any file manager
///   on Android can open them.
///
/// Uses [ZipFileEncoder] + [InputFileStream] which stream both the
/// input files and the output archive directly to/from disk, so
/// memory usage stays small (a few MB) even for multi-GB sources.
class ZipEngine {
  /// Package a file or directory into a STORED-mode zip on disk.
  ///
  /// - Streams input files and output archive (no full in-memory build).
  /// - Each entry is forced to `CompressionType.none` (STORED).
  /// - Returns the output file path.
  static Future<String> compressToFile(
    String sourcePath,
    String outputPath,
  ) async {
    final entity = FileSystemEntity.typeSync(sourcePath);
    final encoder = ZipFileEncoder();
    encoder.create(outputPath);

    try {
      if (entity == FileSystemEntityType.directory) {
        await _addDirectoryStored(encoder, Directory(sourcePath));
      } else if (entity == FileSystemEntityType.file) {
        _addFileStored(
          encoder,
          File(sourcePath),
          p.basename(sourcePath),
        );
      } else {
        throw ArgumentError(
          'Path does not exist or is not a file/directory: $sourcePath',
        );
      }
    } finally {
      await encoder.close();
    }
    return outputPath;
  }

  /// Walk a directory and add every file with STORED compression.
  /// Streams each file via [InputFileStream] — never loads file contents
  /// into memory.
  static Future<void> _addDirectoryStored(
    ZipFileEncoder encoder,
    Directory dir,
  ) async {
    await for (final entity in dir.list(recursive: true, followLinks: true)) {
      if (entity is File) {
        final relPath = p.posix.fromUri(
          p.toUri(p.relative(entity.path, from: dir.path)),
        );
        _addFileStored(encoder, entity, relPath);
      }
    }
  }

  /// Add a single file as a STORED entry (no compression). Streams from
  /// disk via [InputFileStream] so big files don't eat memory.
  static void _addFileStored(
    ZipFileEncoder encoder,
    File file,
    String entryName,
  ) {
    final inputStream = InputFileStream(file.path);
    final archiveFile = ArchiveFile.stream(entryName, inputStream)
      ..compression = CompressionType.none // ← force STORED
      ..lastModTime =
          file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000
      ..mode = file.statSync().mode;
    encoder.addArchiveFile(archiveFile);
  }
}
