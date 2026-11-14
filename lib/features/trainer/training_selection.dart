import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/training/schedule.dart';
import '../../chess/training/training_options.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_repository.dart';
import '../../storage/settings_store.dart';
import '../../workspace/book/repertoire_catalog.dart';

/// The trainer's chosen repertoire and browsing scope, independent of the
/// document on the board. Browsing never starts or replaces a lesson.
final class TrainingSelection extends ChangeNotifier {
  TrainingSelection(this.catalog, this.settings)
    : _seen = catalog?.inputsRevision ?? 0 {
    catalog?.addListener(_catalogChanged);
  }

  final RepertoireCatalog? catalog;
  final SettingsStore? settings;
  bool active = false;
  String root = '';
  ChapterRef? chapter;
  LineKey? line;
  final Set<LineKey> picked = {};
  bool choosing = false;

  void chooseLines(bool on) {
    choosing = on;
    picked.clear();
    notifyListeners();
  }

  TrainingOptions get options => settings?.value.training ?? _options;
  TrainingOptions _options = TrainingOptions.defaults;
  List<RepertoireFolder> get repertoires => catalog?.repertoires ?? const [];
  RepertoireFolder? get repertoire =>
      repertoires.where((r) => r.path == root).firstOrNull;
  String get title =>
      chapter?.name ?? repertoire?.name ?? 'Choose a repertoire';

  void enter(ChapterRef? current) {
    if (active) return;
    active = true;
    root = options.repertoirePath;
    if (root.isEmpty && current != null) {
      root = catalog?.repertoireOf(current.path) ?? '';
    }
    chapter = null;
    line = null;
    picked.clear();
    choosing = false;
    if (root.isNotEmpty) update(options.copyWith(repertoirePath: root));
    notifyListeners();
    _adoptOnly();
  }

  /// With nothing chosen and one repertoire to train, that one is the
  /// choice: the list may be read after the trainer is entered.
  void _adoptOnly() {
    if (!active || root.isNotEmpty || repertoires.length != 1) return;
    choose(repertoires.single);
  }

  /// The catalog's [RepertoireCatalog.inputsRevision] last followed.
  int _seen;

  void _catalogChanged() {
    _followMove();
    _adoptOnly();
  }

  /// A repertoire or chapter renamed or moved takes the choice of it and its
  /// pauses along. Both are settings keyed by path, so without this a
  /// renamed repertoire is no longer chosen and a paused chapter's lines
  /// come back into Learn and Review under its new name.
  void _followMove() {
    final catalog = this.catalog!;
    if (catalog.inputsRevision == _seen) return;
    _seen = catalog.inputsRevision;
    final change = catalog.admittedChange;
    final to = change?.movedTo;
    if (change == null || change.kind != DocumentChangeKind.moved) return;
    if (to == null) return;
    String? moved(String path) => p.equals(path, change.path)
        ? to
        : p.isWithin(change.path, path)
        ? p.join(to, p.relative(path, from: change.path))
        : null;
    LineKey followed(LineKey key) => switch (moved(key.source)) {
      final source? => (source: source, id: key.id),
      null => key,
    };
    final before = (root, chapter, line, {...picked});
    root = moved(root) ?? root;
    if (chapter case final ref?) {
      chapter = ref.inFile(moved(ref.path) ?? ref.path);
    }
    if (line case final key?) line = followed(key);
    picked
      ..clear()
      ..addAll(before.$4.map(followed));
    final scopes = {
      for (final key in options.pausedScopes) _movedScope(key, moved) ?? key,
    };
    final path = moved(options.repertoirePath);
    if (path == null && setEquals(scopes, options.pausedScopes)) {
      if (before.$1 != root ||
          before.$2?.path != chapter?.path ||
          before.$3 != line ||
          !setEquals(before.$4, picked)) {
        notifyListeners();
      }
      return;
    }
    update(
      options.copyWith(
        repertoirePath: path,
        pausedScopes: Set.unmodifiable(scopes),
      ),
    );
  }

  /// [key] — a repertoire's folder, or a chapter's [chapterKey] — where
  /// [moved] put it; null when it did not move.
  static String? _movedScope(String key, String? Function(String) moved) {
    if (!key.startsWith('[')) return moved(key);
    final Object? decoded;
    try {
      decoded = jsonDecode(key);
    } on FormatException catch (error) {
      log.w('follow the paused training scope $key', error);
      return null;
    }
    if (decoded case [final String path, final String? section]) {
      final to = moved(path);
      return to == null ? null : jsonEncode([to, section]);
    }
    return null;
  }

  @override
  void dispose() {
    catalog?.removeListener(_catalogChanged);
    super.dispose();
  }

  void followDocument() {
    if (!active && !choosing) return;
    active = false;
    chapter = null;
    line = null;
    picked.clear();
    // Choosing lines belongs to the trainer mode; left on, it would hide
    // every line from the builder's and Study's Train tabs.
    choosing = false;
    notifyListeners();
  }

  void choose(RepertoireFolder repertoire) {
    active = true;
    root = repertoire.path;
    chapter = null;
    line = null;
    picked.clear();
    choosing = false;
    update(options.copyWith(repertoirePath: root));
    notifyListeners();
  }

  void select({ChapterRef? chapter, LineKey? line}) {
    this.chapter = chapter;
    this.line = line;
    picked.clear();
    choosing = false;
    notifyListeners();
  }

  void pick(LineKey key, bool on) {
    on ? picked.add(key) : picked.remove(key);
    notifyListeners();
  }

  static String chapterKey(ChapterRef ref) =>
      jsonEncode([ref.path, ref.section]);
  bool get repertoirePaused => options.pausedScopes.contains(root);
  bool chapterPaused(ChapterRef ref) =>
      repertoirePaused || options.pausedScopes.contains(chapterKey(ref));
  bool get scopePaused =>
      chapter == null ? repertoirePaused : chapterPaused(chapter!);

  void pauseScope(bool paused, {ChapterRef? chapter}) {
    final key = chapter == null ? root : chapterKey(chapter);
    final next = {...options.pausedScopes};
    paused ? next.add(key) : next.remove(key);
    update(options.copyWith(pausedScopes: Set.unmodifiable(next)));
  }

  void update(TrainingOptions next) {
    _options = next;
    final store = settings;
    if (store != null) {
      unawaited(store.update(store.value.copyWith(training: next)));
    }
    notifyListeners();
  }
}
