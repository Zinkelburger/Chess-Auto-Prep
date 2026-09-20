/// A PGN file under the app's documents root, named by its absolute path.
///
/// This is the one identity for "a file the store owns"; [ChapterRef] in
/// `chapter_files.dart` is this type with the two labels the library list
/// shows.
base class DocumentRef {
  const DocumentRef(this.path);

  /// Absolute, as the operating system spells it.
  final String path;

  @override
  bool operator ==(Object other) => other is DocumentRef && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => path;
}

/// What a document looked like when it was read: the SHA-256 of the exact
/// bytes, and the file's native identity (device and inode on Linux) from the
/// same open handle.
///
/// A save proceeds only when both still match. New bytes under the same name
/// mean someone else edited the document; the same bytes in a different file
/// mean the name now points somewhere else. Either way the user's save would
/// be writing over an answer it never saw, so both are a conflict.
final class Revision {
  const Revision({required this.contentHash, required this.identity});

  /// Lowercase hex SHA-256 of the file's bytes.
  final String contentHash;

  /// The native object identity, opaque and only ever compared.
  final String identity;

  @override
  bool operator ==(Object other) =>
      other is Revision &&
      other.contentHash == contentHash &&
      other.identity == identity;

  @override
  int get hashCode => Object.hash(contentHash, identity);

  @override
  String toString() => '${contentHash.substring(0, 8)}@$identity';
}
