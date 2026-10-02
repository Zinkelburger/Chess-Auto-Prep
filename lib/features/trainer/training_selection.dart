import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../chess/training/schedule.dart';
import '../../chess/training/training_options.dart';
import '../../storage/chapter_files.dart';
import '../../storage/settings_store.dart';
import '../../workspace/repertoire_catalog.dart';

/// The trainer's chosen repertoire and browsing scope, independent of the
/// document on the board. Browsing never starts or replaces a lesson.
final class TrainingSelection extends ChangeNotifier {
  TrainingSelection(this.catalog, this.settings);

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
    if (root.isNotEmpty) update(options.copyWith(repertoirePath: root));
    notifyListeners();
  }

  void followDocument() {
    if (!active) return;
    active = false;
    chapter = null;
    line = null;
    picked.clear();
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
    if (store != null)
      unawaited(store.update(store.value.copyWith(training: next)));
    notifyListeners();
  }
}
