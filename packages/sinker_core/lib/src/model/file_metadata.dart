import 'dart:io';

/// Metadata about a local file or directory to be transferred.
class FileMetadata {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;

  const FileMetadata({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
  });

  /// Create metadata from a file system path.
  static Future<FileMetadata> fromPath(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      throw ArgumentError('Path not found: $path');
    }

    final isDir = type == FileSystemEntityType.directory;
    final name = path.split(Platform.pathSeparator).last;
    final size = isDir ? await _directorySize(path) : await File(path).length();

    return FileMetadata(
      path: path,
      name: name,
      isDirectory: isDir,
      size: size,
    );
  }

  static Future<int> _directorySize(String path) async {
    var total = 0;
    await for (final entity in Directory(path).list(recursive: true)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  @override
  String toString() => 'FileMetadata($name, ${isDirectory ? "dir" : "file"}, $size bytes)';
}
