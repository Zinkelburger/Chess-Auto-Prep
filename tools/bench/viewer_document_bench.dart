/// Plain-Dart ownership/projection diagnostic (no Flutter test binding).
/// scripts/ci.sh with -- dart run tools/bench/viewer_document_bench.dart
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_game_controller.dart';
import '../../test/support/large_study_fixture.dart';

void main() {
  final timings = <String, int>{};
  T measure<T>(String name, T Function() action) {
    final watch = Stopwatch()..start();
    final result = action();
    timings[name] = watch.elapsedMicroseconds;
    return result;
  }

  final parsed = measure('parse_us', () => parsePgnGame(largeStudyPgn()));
  final owner = ViewerGameController();
  measure('adopt_us', () => owner.load(parsed));
  final before = measure('project_us', () => owner.variationsByPly);
  var leaf = before[0]!.first;
  while (leaf.children.isNotEmpty) {
    leaf = leaf.children.first;
  }
  final after = measure('edit_and_project_us', () {
    owner.setNodeComment(leaf, 'Benchmark edit');
    return owner.variationsByPly;
  });
  final shared = [
    for (var i = 1; i < before[0]!.length; i++)
      identical(before[0]![i], after[0]![i]),
  ];
  final refreshed = measure('annotation_refresh_and_project_us', () {
    if (!owner.adoptAnnotations(parsed)) {
      throw StateError('Unchanged topology rejected');
    }
    return owner.variationsByPly;
  });
  final refreshShared = [
    for (var i = 1; i < after[0]!.length; i++)
      identical(after[0]![i], refreshed[0]![i]),
  ];
  owner.goToMainLineMove(100);
  if (shared.any((same) => !same) ||
      !identical(refreshed, owner.variationsByPly) ||
      refreshShared.any((same) => !same) ||
      owner.findNodeById(leaf.id)!.comment == 'Benchmark edit' ||
      leaf.comment == 'Benchmark edit') {
    throw StateError('Ownership/projection contract failed');
  }
  // ignore: avoid_print
  print(
    jsonEncode({
      ...timings,
      'unchanged_roots_shared': shared.length,
      'refresh_unchanged_roots_shared': refreshShared.length,
      'rss_bytes': ProcessInfo.currentRss,
    }),
  );
}
