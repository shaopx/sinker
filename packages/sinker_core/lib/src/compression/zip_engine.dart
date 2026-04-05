import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// ZIP compression and decompression engine.
class ZipEngine {
  /// Compress a file or directory to a zip file on disk.
  ///
  /// This is the recommended method for large files/directories as it
  /// avoids loading the entire archive into memory.
  ///
  /// Returns the output file path.
  static Future<String> compressToFile(String sourcePath, String outputPath) async {
    final entity = FileSystemEntity.typeSync(sourcePath);
    final archive = Archive();

    if (entity == FileSystemEntityType.directory) {
      await _addDirectoryToArchive(archive, Directory(sourcePath), sourcePath);
    } else if (entity == FileSystemEntityType.file) {
      await _addFileToArchive(archive, File(sourcePath), File(sourcePath).parent.path);
    } else {
      throw ArgumentError('Path does not exist or is not a file/directory: $sourcePath');
    }

    final encoded = ZipEncoder().encode(archive);
    await File(outputPath).writeAsBytes(encoded);
    return outputPath;
  }

  /// Compress a file or directory to a zip archive in memory.
  ///
  /// WARNING: For large files (>100MB), use [compressToFile] instead
  /// to avoid OutOfMemoryError.
  static Future<Uint8List> compress(String path) async {
    final entity = FileSystemEntity.typeSync(path);
    final archive = Archive();

    if (entity == FileSystemEntityType.directory) {
      await _addDirectoryToArchive(archive, Directory(path), path);
    } else if (entity == FileSystemEntityType.file) {
      await _addFileToArchive(archive, File(path), File(path).parent.path);
    } else {
      throw ArgumentError('Path does not exist or is not a file/directory: $path');
    }

    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded);
  }

  /// Extract a zip file from disk to a target directory.
  static Future<void> extractFile(String zipPath, String targetDir) async {
    final bytes = await File(zipPath).readAsBytes();
    await extract(bytes, targetDir);
  }

  /// Extract a zip archive from bytes to a target directory.
  static Future<void> extract(Uint8List zipData, String targetDir) async {
    final archive = ZipDecoder().decodeBytes(zipData);
    final dir = Directory(targetDir);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    for (final file in archive) {
      final filePath = '${targetDir}/${file.name}';
      if (file.isFile) {
        final outFile = File(filePath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(filePath).create(recursive: true);
      }
    }
  }

  static Future<void> _addDirectoryToArchive(
    Archive archive,
    Directory dir,
    String basePath,
  ) async {
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        await _addFileToArchive(archive, entity, basePath);
      }
    }
  }

  static Future<void> _addFileToArchive(
    Archive archive,
    File file,
    String basePath,
  ) async {
    final relativePath = file.path.substring(basePath.length + 1);
    final bytes = await file.readAsBytes();
    archive.addFile(ArchiveFile(relativePath, bytes.length, bytes));
  }
}
