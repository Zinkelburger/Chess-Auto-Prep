/// The list of PGN sources behind [PgnSourcesPanel].
///
/// The panel is mounted only in DB Explorer mode, but the form reads the
/// files at Start and seeds them from a config or from the games screen, so
/// the list outlives the widget that edits it.
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/pgn_filter_models.dart';
import '../models/pgn_source.dart';

/// The PGN files and pastes one build may draw its games from.
class PgnSourcesController extends ChangeNotifier {
  final List<PgnSource> _sources = [];

  List<PgnSource> get sources => List.unmodifiable(_sources);

  bool get isEmpty => _sources.isEmpty;

  /// The sources backed by a file on disk — the only ones a build can read.
  /// A pasted source has no path and is silently not one of these.
  List<String> get filePaths => [
    for (final source in _sources)
      if (source.filePath != null) source.filePath!,
  ];

  bool hasFile(String path) => _sources.any((s) => s.filePath == path);

  void add(PgnSource source) {
    _sources.add(source);
    notifyListeners();
  }

  void removeAt(int index) {
    _sources.removeAt(index);
    notifyListeners();
  }

  /// Replaces the list with one source per path, named after its file.
  ///
  /// The single way a path list becomes sources, so seeding from a saved
  /// config and seeding from the games screen cannot drift apart.
  void seedFromPaths(Iterable<String> paths) {
    _sources
      ..clear()
      ..addAll(
        paths.map(
          (path) => PgnSource(
            id: PgnSource.generateId(),
            name: p.basenameWithoutExtension(path),
            filePath: path,
          ),
        ),
      );
    notifyListeners();
  }

  /// Records the outcome of the inline slice editor for one source.
  void applySlice(
    PgnSource source, {
    required SliceConfig? config,
    required List<int>? matchedIndices,
  }) {
    source.sliceConfig = config;
    source.matchedIndices = matchedIndices;
    notifyListeners();
  }
}
