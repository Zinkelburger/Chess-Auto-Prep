import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'bughouse_books.dart';

/// A single accepted analysis, including its stable history identity. The
/// payload is copied before asynchronous persistence or owner disposal.
final class HivemindWrite {
  HivemindWrite(HivemindEntry entry)
    : entry = (
        position: entry.position,
        line: entry.line,
        ply: entry.ply,
        clock: entry.clock,
        picks: Map.unmodifiable(entry.picks),
        moves: Map.unmodifiable(entry.moves),
        nodes: entry.nodes,
        childNodes: entry.childNodes,
        took: entry.took,
        provenance: _freeze(entry.provenance) as Map<String, Object?>,
      ),
      id =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}',
      completedAt = DateTime.now().toUtc().toIso8601String();

  final HivemindEntry entry;
  final String id;
  final String completedAt;
  String? _path;
  String get digest => analysisDigest(entry);

  /// An exact retry must never choose a newly available fallback database.
  void bind(String path, HivemindEntry submitted) {
    if ((_path != null && _path != path) ||
        analysisDigest(submitted) != digest) {
      throw StateError('The accepted analysis payload or destination changed.');
    }
    _path = path;
  }
}

String analysisDigest(HivemindEntry entry) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          entry.position.dualFen,
          entry.line,
          entry.ply,
          entry.clock.bookName,
          [
            for (final item in entry.picks.entries)
              [
                item.key.name,
                item.value.best,
                item.value.score.score,
                item.value.score.mate,
                item.value.pv,
                item.value.offset,
              ],
          ],
          [
            for (final item in entry.moves.entries)
              [
                item.key.$1.name,
                item.key.$2,
                item.value.score.score,
                item.value.score.mate,
                item.value.pv,
              ],
          ],
          entry.nodes,
          entry.childNodes,
          entry.took.inMicroseconds,
          entry.provenance,
        ]),
      ),
    )
    .toString();

Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?>() => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries) entry.key: _freeze(entry.value),
  }),
  List<Object?>() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
