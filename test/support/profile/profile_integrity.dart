// What a profile's references resolve to, read with v2's own readers
// (parseChapter, trainedIdsOf, chapterSections): training keys and book
// selectors that name nothing, and every game the profile holds anywhere, so
// a contract can say whether an operation orphaned a reference or lost a
// game.
import 'dart:convert';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:chess_auto_prep/storage/backups.dart' show versionBytes;
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'authority.dart';
import 'profile_snapshot.dart';

final class ProfileIntegrity {
  const ProfileIntegrity._({
    required this.orphanKeys,
    required this.unresolvedSelectors,
    required this.liveGames,
    required this.heldGames,
    required this.liveFiles,
    required this.heldFiles,
  });

  /// `<training file>: <repertoire_id> <line_id>` for each record whose
  /// chapter is not there or trains no line of that id. A chapter a delete
  /// set aside still counts: restore brings its references back with it.
  final Set<String> orphanKeys;

  /// `<book id>: <path>` or `<book id>: <path>#<section>` for each book
  /// entry that names no repertoire folder, file or course chapter. A
  /// chapter a delete set aside still counts, as for [orphanKeys].
  final Set<String> unresolvedSelectors;

  /// The hash of each game in a live PGN, with how many times it occurs.
  final Map<String, int> liveGames;

  /// The games in kept versions, quarantine and the deleted-chapter and
  /// reference histories.
  final Set<String> heldGames;

  /// The hash of each live PGN's bytes.
  final Set<String> liveFiles;

  /// The hash of each PGN held outside the live files, as it was kept.
  final Set<String> heldFiles;

  bool holdsGame(String hash) =>
      liveGames.containsKey(hash) || heldGames.contains(hash);

  bool holdsFile(String hash) =>
      liveFiles.contains(hash) || heldFiles.contains(hash);

  factory ProfileIntegrity.of(ProfileSnapshot snapshot) {
    final chapters = _Chapters(snapshot);
    final liveGames = <String, int>{};
    final heldGames = <String>{};
    final liveFiles = <String>{};
    final heldFiles = <String>{};
    for (final name in chapters.names) {
      final live = snapshot.classOf(name) == Authority.authoritative;
      (live ? liveFiles : heldFiles).add(chapters.fileHash(name));
      for (final game in chapters.of(name).lines) {
        final hash = gameHash(game.text);
        if (live) {
          liveGames.update(hash, (n) => n + 1, ifAbsent: () => 1);
        } else {
          heldGames.add(hash);
        }
      }
    }
    return ProfileIntegrity._(
      orphanKeys: _orphanKeys(snapshot, chapters),
      unresolvedSelectors: _unresolvedSelectors(snapshot, chapters),
      liveGames: liveGames,
      heldGames: heldGames,
      liveFiles: liveFiles,
      heldFiles: heldFiles,
    );
  }
}

/// A game by its text, whatever file or place holds it.
String gameHash(String text) =>
    '${sha256.convert(utf8.encode(text.trimRight()))}';

/// Every PGN the profile holds, parsed once: live chapters, kept versions
/// and what recovery or a delete set aside. Downloaded games are derived and
/// left out.
final class _Chapters {
  _Chapters(this.snapshot)
    : names = [
        for (final MapEntry(:key, :value) in snapshot.entries.entries)
          if (value is FileEntry && _holdsGames(snapshot, key)) key,
      ];

  final ProfileSnapshot snapshot;
  final List<String> names;
  final _parsed = <String, Chapter>{};

  List<int> _bytes(String name) {
    final stored = snapshot.bytes(name)!;
    return snapshot.classOf(name) == Authority.kept
        ? versionBytes(stored)
        : stored;
  }

  String fileHash(String name) => '${sha256.convert(_bytes(name))}';

  Chapter of(String name) => _parsed.putIfAbsent(
    name,
    () => parseChapter(
      name: p.posix.basenameWithoutExtension(name),
      text: utf8.decode(_bytes(name), allowMalformed: true),
    ),
  );

  /// Whether a live or set-aside chapter is at [name].
  bool holds(String name) =>
      names.contains(name) && snapshot.classOf(name) != Authority.kept;

  /// The ids the chapter file [name] trains lines under, or null when no
  /// live or set-aside chapter is there.
  Set<String>? trainedAt(String name) =>
      holds(name) ? trainedIdsOf(of(name)).nonNulls.toSet() : null;
}

bool _holdsGames(ProfileSnapshot snapshot, String name) {
  if (!name.toLowerCase().contains('.pgn')) return false;
  return switch (snapshot.classOf(name)) {
    Authority.authoritative || Authority.kept || Authority.recovery => true,
    _ => false,
  };
}

Set<String> _orphanKeys(ProfileSnapshot snapshot, _Chapters chapters) {
  final orphans = <String>{};
  for (final file in [reviewsFile, streaksFile, historyFile, attemptsFile]) {
    final text = snapshot.text('Documents/$file');
    if (text == null) continue;
    for (final (source, id) in _keysIn(file, text)) {
      final name = p.isWithin(snapshot.root, source)
          ? snapshot.nameOf(source)
          : null;
      final ids = name == null ? null : chapters.trainedAt(name);
      if (ids == null || !ids.contains(id)) orphans.add('$file: $source $id');
    }
  }
  return orphans;
}

/// The (repertoire_id, line_id) of each record of the training file [file]
/// that this app can read; the rest are the stores' concern, not a key.
Iterable<(String, String)> _keysIn(String file, String text) sync* {
  final body = text.startsWith('\uFEFF') ? text.substring(1) : text;
  if (file == attemptsFile) {
    for (final line in const LineSplitter().convert(body)) {
      final Object? json;
      try {
        json = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (json case {
        'repertoireId': final String s,
        'lineId': final String i,
      }) {
        yield (s, i);
      }
    }
    return;
  }
  if (readCsvRecords(body) case CsvParsed(:final records)) {
    final header = headerWidth(records);
    for (final record in records) {
      final cells = dataCells(record, rowWidth(file, record, header));
      if (cells != null && cells.length >= 2) yield (cells[0], cells[1]);
    }
  }
}

Set<String> _unresolvedSelectors(ProfileSnapshot snapshot, _Chapters chapters) {
  final text = snapshot.text('Support/books.json');
  if (text == null) return const {};
  final BookList books;
  try {
    books = BookList.decode(text);
  } on FormatException {
    return const {};
  }
  final unresolved = <String>{};
  for (final book in books.books) {
    for (final folder in book.repertoires) {
      if (snapshot.entries['Documents/repertoires/$folder']
          is! DirectoryEntry) {
        unresolved.add('${book.id}: $folder');
      }
    }
    for (final BookChapter(:path, :section) in book.chapters) {
      final name = 'Documents/repertoires/$path';
      if (!chapters.holds(name) ||
          (section != null &&
              !chapterSections(chapters.of(name).lines).contains(section))) {
        unresolved.add(
          '${book.id}: $path${section == null ? '' : '#$section'}',
        );
      }
    }
  }
  return unresolved;
}
