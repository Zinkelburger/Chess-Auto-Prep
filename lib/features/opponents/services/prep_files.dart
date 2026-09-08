/// A person's prep file is a study: one PGN, chapters for sections. It is
/// created on first use with an "As White" and an "As Black" chapter so the
/// two halves of the prep are there to write into, and lines added from
/// Player Analysis land as further chapters named by the colour you hold —
/// one chapter per line, because the trainer drills chapters.
library;

import 'package:path/path.dart' as p;

import '../../../models/study_document.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../services/storage/study_naming.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';
import 'opponent_store.dart';
import 'tournament_text_export.dart';

class PrepFiles {
  PrepFiles(this.store);

  final OpponentStore store;

  static String nameFor(PersonRecord person) => 'Prep – ${person.name}';

  /// The person's prep file, created now if there is none (or the one on
  /// record has gone missing). Returns its path.
  Future<String> ensure(PersonRecord person) async {
    final storage = StorageFactory.instance;
    final existing = person.prepFilePath;
    if (existing != null && await storage.fileExists(existing)) return existing;
    final reserved = await reserveStudyPath(nameFor(person));
    final doc = StudyDocument(
      name: reserved.name,
      chapters: [
        StudyChapter(name: 'As White'),
        StudyChapter(name: 'As Black'),
      ],
    );
    await storage.writeFile(reserved.path, doc.toPgn(), createOnly: true);
    await store.savePerson(
      (store.person(person.id) ?? person).copyWith(prepFilePath: reserved.path),
    );
    return reserved.path;
  }

  /// The group's own editable study. It is created once, never regenerated.
  Future<String> ensureGroup(Tournament group) async {
    final storage = StorageFactory.instance;
    final current = store.tournament(group.id) ?? group;
    if (current.studyPath != null &&
        await storage.fileExists(current.studyPath!)) {
      return current.studyPath!;
    }
    final reserved = await reserveStudyPath(current.name);
    final chapters = <StudyChapter>[];
    for (final entry in current.entries) {
      final person = store.person(entry.personId);
      if (person == null || person.prepFilePath == null) continue;
      final text = await storage.readFile(person.prepFilePath!);
      if (text == null) continue;
      for (final chapter in StudyDocument.fromPgn(
        text,
        name: person.name,
      ).chapters) {
        if (chapter.tree.isNotEmpty) {
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
    }
    await storage.writeFile(
      reserved.path,
      StudyDocument(
        name: reserved.name,
        chapters: chapters.isEmpty ? [StudyChapter(name: 'Notes')] : chapters,
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

  /// Whether the person's prep file exists on disk.
  Future<bool> exists(PersonRecord person) async {
    final path = person.prepFilePath;
    return path != null && await StorageFactory.instance.fileExists(path);
  }

  /// The chapters of the person's prep file as movetext, for the export.
  /// Empty when there is no file.
  Future<List<PrepChapterText>> chaptersOf(PersonRecord person) async {
    final path = person.prepFilePath;
    if (path == null) return const [];
    final text = await StorageFactory.instance.readFile(path);
    if (text == null) return const [];
    final doc = StudyDocument.fromPgn(
      text,
      name: p.basenameWithoutExtension(path),
      filePath: path,
    );
    return [
      for (final c in doc.chapters)
        PrepChapterText(name: c.name, movetext: c.tree.toPgnMoveText()),
    ];
  }

  /// One study holding every chapter of every prep file in the field, so the
  /// whole tournament's lines train in one sitting. Rewritten each time;
  /// chapters are prefixed with the opponent's name. Null when nobody in the
  /// field has a prep file with moves.
  Future<String?> mergedForTournament(Tournament tournament) async {
    final storage = StorageFactory.instance;
    final chapters = <StudyChapter>[];
    for (final entry in tournament.entries) {
      final person = store.person(entry.personId);
      final path = person?.prepFilePath;
      if (person == null || path == null) continue;
      final text = await storage.readFile(path);
      if (text == null) continue;
      final doc = StudyDocument.fromPgn(
        text,
        name: person.name,
        filePath: path,
      );
      for (final c in doc.chapters) {
        if (c.tree.isEmpty) continue;
        chapters.add(
          StudyChapter(
            name: '${person.name} · ${c.name}',
            headers: Map.of(c.headers),
            tree: c.tree,
          ),
        );
      }
    }
    if (chapters.isEmpty) return null;
    final name = sanitizeStudyName('${tournament.name} – all prep');
    final path = await storage.studyFilePath(name);
    final doc = StudyDocument(name: name, chapters: chapters);
    await storage.writeFile(path, doc.toPgn());
    return path;
  }
}
