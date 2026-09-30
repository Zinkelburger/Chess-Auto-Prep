import 'dart:math';

import 'recovery_files.dart';

/// The name one multi-file change goes by from acceptance until its record is
/// gone: its `<id>.json`, the key an exact retry is answered by, and the
/// `.cap-reference-history/<id>/` folder of the rows it replaced. Every
/// journal uses this one grammar, so an id is a safe file name everywhere.
extension type const OperationId._(String value) implements String {
  /// Throws [RecoveryRequired] outside the grammar: how a damaged record is
  /// told from a real one.
  factory OperationId(String value) {
    if (_grammar.stringMatch(value) != value) {
      throw RecoveryRequired('Unsupported operation id: $value.');
    }
    return OperationId._(value);
  }
}

final _grammar = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');

/// Microseconds, then 32 random bits: ids sort by age, and a deleted
/// chapter's recovery name (`<id>-<name>.pgn`) reads as a time
/// (`validateDeletionId`).
OperationId newOperationId() => OperationId(
  '${DateTime.now().microsecondsSinceEpoch}-'
  '${Random.secure().nextInt(1 << 32).toRadixString(16)}',
);
