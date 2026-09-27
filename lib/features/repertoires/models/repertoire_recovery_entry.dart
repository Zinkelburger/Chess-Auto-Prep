/// Durable recovery receipt. Its id, not a caller-supplied path, authorizes restore.
class RepertoireRecoveryEntry {
  const RepertoireRecoveryEntry({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.deletedAt,
    required this.available,
  });
  final String id;
  final String name;
  final String originalPath;
  final DateTime deletedAt;
  final bool available;
}
