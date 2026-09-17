import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../chess_core/pgn/pgn_position_replay.dart' as pgn;
import '../../features/documents/repositories/viewer_position_index_repository.dart';
import '../../features/documents/repositories/viewer_computation.dart';
import '../../models/pgn_filter_models.dart';
import '../../services/storage/storage_service.dart';
import '../../utils/isolate_task.dart';
import 'isolate_viewer_computation.dart';

/// Version 2 replaces size/mtime validation with an exact source fingerprint.
/// Version 1 companions are ignored and rebuilt; they are disposable caches.
class StorageViewerPositionIndexRepository
    implements ViewerPositionIndexRepository {
  StorageViewerPositionIndexRepository(this.storage);
  final StorageService storage;
  @override
  Future<Map<String, List<int>>?> load(
    String path,
    List<GameRecord> source,
  ) async {
    final raw = await storage.readFile('$path.fenidx');
    if (raw == null) return null;
    return IsolateTask().compute(_decode, (raw, source));
  }

  @override
  ViewerComputation<Map<String, List<int>>> build(List<GameRecord> source) =>
      IsolateViewerComputation(
        (task) => task.compute(pgn.buildFenIndex, source),
      );
  @override
  Future<void> save(
    String path,
    List<GameRecord> source,
    Map<String, List<int>> index,
  ) async {
    final raw = await IsolateTask().compute(_encode, (source, index));
    await storage.writeFile('$path.fenidx', raw);
  }
}

String _fingerprint(List<GameRecord> source) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          for (final game in source)
            [
              {
                for (final key in (game.headers.keys.toList()..sort()))
                  key: game.headers[key],
              },
              game.pgnText,
            ],
        ]),
      ),
    )
    .toString();

String _encode((List<GameRecord>, Map<String, List<int>>) request) =>
    jsonEncode({
      'version': 2,
      'source': _fingerprint(request.$1),
      'index': request.$2,
    });

Map<String, List<int>>? _decode((String, List<GameRecord>) request) {
  final decoded = jsonDecode(request.$1) as Map<String, dynamic>;
  if (decoded['version'] != 2 ||
      decoded['source'] != _fingerprint(request.$2)) {
    return null;
  }
  final raw = decoded['index'] as Map<String, dynamic>;
  final index = <String, List<int>>{};
  for (final entry in raw.entries) {
    final values = (entry.value as List).cast<int>();
    if (values.any((value) => value < 0 || value >= request.$2.length)) {
      return null;
    }
    index[entry.key] = List.unmodifiable(values);
  }
  return Map.unmodifiable(index);
}
