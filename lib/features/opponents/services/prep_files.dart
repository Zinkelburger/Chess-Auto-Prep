/// A person's prep file is a study: one PGN, chapters for sections. It is
/// created on first use with an "As White" and an "As Black" chapter so the
/// two halves of the prep are there to write into, and lines added from
/// Player Analysis land as further chapters named by the colour you hold —
/// one chapter per line, because the trainer drills chapters.
library;

import 'package:path/path.dart' as p;

import '../../studies/models/study_document.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../services/storage/storage_service.dart';
import '../../../services/storage/study_naming.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';
import 'opponent_store.dart';
import 'tournament_text_export.dart';

/// Creates and reads the studies behind people and groups, recording their
/// paths in the [OpponentStore].
class PrepFiles {
  PrepFiles(this.store);

  final OpponentStore store;

  static const _prepChapterNames = ['As White', 'As Black'];
  static const _emptyGroupChapterName = 'Notes';

  StorageService get _storage => StorageFactory.instance;

  /// The study name a person's prep file is created under.
  static String nameFor(PersonRecord person) => 'Prep – ${person.name}';

  /// The person's prep file, created now if there is none (or the one on
  /// record has gone missing). Returns its path.
  Future<String> ensure(PersonRecord person) async {
    final existing = person.prepFilePath;
    if (existing != null && await _storage.fileExists(existing)) {
      return existing;
    }
    final reserved = await reserveStudyPath(nameFor(person));
    final doc = StudyDocument(
      name: reserved.name,
      chapters: [
        for (final name in _prepChapterNames) StudyChapter(name: name),
      ],
    );
    await _storage.writeFile(reserved.path, doc.toPgn(), createOnly: true);
    await store.savePerson(
      (store.person(person.id) ?? person).copyWith(prepFilePath: reserved.path),
    );
    return reserved.path;
  }

  /// The group's own editable study. It is created once — seeded with every
  /// chapter that has moves in the field's prep files — and never
  /// regenerated.
  Future<String> ensureGroup(Tournament group) async {
    final current = store.tournament(group.id) ?? group;
    final existing = current.studyPath;
    if (existing != null && await _storage.fileExists(existing)) {
      return existing;
    }
    final reserved = await reserveStudyPath(current.name);
    final chapters = <StudyChapter>[];
    for (final entry in current.entries) {
      final person = store.person(entry.personId);
      final path = person?.prepFilePath;
      if (person == null || path == null) continue;
      final doc = await _readStudy(path, name: person.name);
      if (doc == null) continue;
      for (final chapter in doc.chapters) {
        if (chapter.tree.isEmpty) continue;
        chapters.add(
          StudyChapter(
            name: '${person.name} · ${chapter.name}',
            orientation: chapter.orientation,
            headers: Map.of(chapter.headers),
            tree: chapter.tree,
          ),
        );
      }
    }
    await _storage.writeFile(
      reserved.path,
      StudyDocument(
        name: reserved.name,
        chapters: chapters.isEmpty
            ? [StudyChapter(name: _emptyGroupChapterName)]
            : chapters,
      ).toPgn(),
      createOnly: true,
    );
    await store.saveTournament(
      (store.tournament(group.id) ?? current).copyWith(
        studyPath: reserved.path,
      ),
    );
    return reserved.path;
  }

  /// Where a line for [person] should land: their own prep file, or the
  /// group's study when they are being prepared as part of [group] — which
  /// is then linked from their row.
  Future<String> preferredFor(PersonRecord person, Tournament? group) async {
    if (group == null) return ensure(person);
    final path = await ensureGroup(group);
    final current = store.person(person.id) ?? person;
    if (!current.studyLinks.any((link) => link.path == path)) {
      await store.savePerson(
        current.copyWith(
          studyLinks: [
            ...current.studyLinks,
            PlayerStudyLink(path: path),
          ],
        ),
      );
    }
    return path;
  }

  /// The chapters of the person's prep file as movetext, for the export.
  /// Empty when there is no file.
  Future<List<PrepChapterText>> chaptersOf(PersonRecord person) async {
    final path = person.prepFilePath;
    if (path == null) return const [];
    final doc = await _readStudy(path, name: p.basenameWithoutExtension(path));
    if (doc == null) return const [];
    return [
      for (final c in doc.chapters)
        PrepChapterText(name: c.name, movetext: c.tree.toPgnMoveText()),
    ];
  }

  /// The study at [path], or null when it is not readable.
  Future<StudyDocument?> _readStudy(String path, {required String name}) async {
    final text = await _storage.readFile(path);
    if (text == null) return null;
    return StudyDocument.fromPgn(text, name: name, filePath: path);
  }
}
