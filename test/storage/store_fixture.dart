// A throwaway Documents and Support pair for the store tests. Nothing here
// touches the profile the app really uses.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/diagnostics/log.dart';
import 'package:chess_auto_prep/storage/backups.dart';
import 'package:chess_auto_prep/storage/document_probe.dart';
import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:crypto/crypto.dart';
import 'package:document_file_io/document_file_io.dart'
    show NativeCall, runWithNativeCalls, syncDirectory;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final class StoreFixture {
  StoreFixture._(
    this.root,
    this.documents,
    this.support, {
    Future<void> Function(String)? synchronize,
  }) : store = PgnFileStore(
         documents: documents,
         support: support,
         synchronize: synchronize ?? syncDirectory,
       );

  /// [synchronize] stands in for the directory flush of a plain create or
  /// save, for a test of a disk that cannot flush one.
  static Future<StoreFixture> create({
    Future<void> Function(String)? synchronize,
  }) async {
    final root = await Directory.systemTemp.createTemp('v2-store-');
    final documents = Directory(p.join(root.path, 'Documents'));
    final support = Directory(p.join(root.path, 'Support'));
    await documents.create(recursive: true);
    await support.create(recursive: true);
    return StoreFixture._(root, documents, support, synchronize: synchronize);
  }

  final Directory root;
  final Directory documents;
  final Directory support;
  final PgnFileStore store;

  DocumentRef ref(String relative) =>
      DocumentRef(p.join(documents.path, p.joinAll(relative.split('/'))));

  /// Puts [text] on disk through the store and returns its revision.
  Future<Revision> put(DocumentRef ref, String text) async {
    final created = await store.create(ref, text);
    return (created as Created).revision;
  }

  Directory backupFolder(DocumentRef ref) => Directory(
    p.join(
      support.path,
      'backups',
      backupId(p.relative(ref.path, from: documents.path)),
    ),
  );

  /// Replaces [ref] with [text] as an edit to its first game, which is what
  /// a save of a one-game chapter says, so the tests run under the check
  /// that stops a save changing any other game.
  Future<SaveResult> edit(DocumentRef ref, String text, Revision expected) =>
      store.save(
        ref,
        text,
        expected: expected,
        scope: GamesEdited(GamesWritten(rewritten: const {0})),
      );

  /// Puts a version the store recorded back, which is what an undo does.
  Future<SaveResult> restore(DocumentRef ref, String text, Revision expected) =>
      store.save(ref, text, expected: expected, scope: const RestoredVersion());

  /// Replaces [ref] with [text], the whole document at a time, which is what
  /// an import does.
  Future<SaveResult> replace(DocumentRef ref, String text, Revision expected) =>
      store.save(ref, text, expected: expected, scope: const WholeDocument());

  /// What is on disk at [ref] now, for a test that put it there itself.
  Future<Revision> revisionOf(DocumentRef ref) async =>
      (await probeDocument(ref.path) as FileFound).revision;

  /// The versions kept for [ref], oldest first, as the index lists them.
  List<String> keptVersions(DocumentRef ref) {
    final index = File(p.join(backupFolder(ref).path, 'index.json'));
    if (!index.existsSync()) return const [];
    final json = jsonDecode(index.readAsStringSync()) as Map<String, Object?>;
    return [
      for (final version in json['versions']! as List<Object?>)
        (version! as Map<String, Object?>)['file']! as String,
    ];
  }

  /// The text of each kept version, oldest first.
  List<String> keptTexts(DocumentRef ref) => [
    for (final name in keptVersions(ref))
      utf8.decode(
        versionBytes(
          File(p.join(backupFolder(ref).path, name)).readAsBytesSync(),
        ),
      ),
  ];

  /// Writes the four training files and books.json, each with one row or
  /// selector naming [chapter], for a test of what a move carries along.
  Future<void> train(DocumentRef chapter) async {
    for (final entry in _training(chapter.path).entries) {
      await File(p.join(documents.path, entry.key)).writeAsString(entry.value);
    }
    await File(p.join(support.path, 'books.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'books': [
          {
            'id': 'book',
            'name': 'Book',
            'repertoires': <String>[],
            'chapters': [
              {'path': _selector(chapter), 'section': null},
            ],
          },
        ],
      }),
    );
  }

  /// Checks that every row and selector [train] wrote now names [chapter].
  Future<void> expectTrained(DocumentRef chapter) async {
    for (final entry in _training(chapter.path).entries) {
      expect(
        await File(p.join(documents.path, entry.key)).readAsString(),
        entry.value,
      );
    }
    final books =
        jsonDecode(
              await File(p.join(support.path, 'books.json')).readAsString(),
            )
            as Map<String, Object?>;
    expect(((books['books']! as List).single as Map)['chapters'], [
      {'path': _selector(chapter), 'section': null},
    ]);
  }

  String _selector(DocumentRef chapter) => p.posix.joinAll(
    p.split(
      p.relative(chapter.path, from: p.join(documents.path, 'repertoires')),
    ),
  );

  Map<String, String> _training(String path) => {
    reviewsFile:
        'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded\n'
        '$path,line,Main,2.5,1,2026-09-01T00:00:00Z,good,2026-08-31T00:00:00Z,2,0,false\n',
    streaksFile: '$streaksHeader\n$path,line,1,2,true\n',
    historyFile:
        'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type\n'
        '$path,line,2026-08-31T00:00:00Z,good,false,trainer\n',
    attemptsFile: '${jsonEncode({'repertoireId': path})}\n',
  };

  /// Files a recovery set aside rather than finished.
  List<File> quarantined() {
    final folder = Directory(p.join(support.path, 'recovery-quarantine'));
    if (!folder.existsSync()) return const [];
    return folder.listSync(recursive: true).whereType<File>().toList();
  }

  /// Relocation records still waiting to finish.
  List<FileSystemEntity> unfinishedMoves() {
    final folder = Directory(p.join(support.path, 'relocation-writes'));
    return folder.existsSync() ? folder.listSync() : const [];
  }

  Future<void> dispose() async {
    // A test may have taken permissions away to provoke a failure.
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwX', root.path]);
    }
    await root.delete(recursive: true);
  }
}

/// [body] on a disk where every folder flush at or under [under] fails
/// with [errno] while [failing] says so, as the native call reports it:
/// EINVAL (22) where the filesystem cannot flush a folder at all, EIO (5)
/// where the flush failed.
Future<T> withFolderFlushFailing<T>(
  String under,
  int errno,
  Future<T> Function() body, {
  bool Function()? failing,
}) => runWithNativeCalls(<R>(
  NativeCall call,
  List<String> paths,
  Future<R> Function() real,
) {
  final path = paths.first;
  if (call == NativeCall.syncDirectory &&
      (failing?.call() ?? true) &&
      (path == under || p.isWithin(under, path))) {
    throw FileSystemException(
      'Directory synchronization unavailable or failed',
      path,
      OSError('Native directory sync', errno),
    );
  }
  return real();
}, body);

/// Leaves in [support] the four-key note an older build wrote before it
/// renamed [from] to [to]; this build only reads and finishes them.
Future<File> leaveMoveNote(
  Directory support,
  String id, {
  required String from,
  required String to,
  required String identity,
  required bool folder,
}) async {
  final note = File(p.join(support.path, 'unfinished-moves', '$id.json'));
  await note.parent.create(recursive: true);
  await note.writeAsString(
    jsonEncode({
      'from': from,
      'to': to,
      'identity': identity,
      'folder': folder,
    }),
  );
  return note;
}

/// The notes older builds left in [support] that are still to finish.
List<FileSystemEntity> notedMoves(Directory support) {
  final folder = Directory(p.join(support.path, 'unfinished-moves'));
  return folder.existsSync() ? folder.listSync() : const [];
}

/// A step hook that stops its command, by throwing, the first time it
/// reaches the step named [step]; with no step it never stops.
Future<void> Function(T) stopOnceAt<T extends Enum>(String? step) {
  var stopped = false;
  return (reached) async {
    if (reached.name == step && !stopped) {
      stopped = true;
      throw StateError('stopped at $step');
    }
  };
}

/// Names for what files hold, so a recorded outcome reads "A:before" rather
/// than a hash. The profile's own path is spelt `<root>` before anything is
/// named or hashed, so two runs on different temporary folders agree.
final class ContentLabels {
  ContentLabels(Directory root)
    // The longer spelling goes first: on macOS the resolved /private/var/...
    // holds the temporary /var/... path inside it.
    : _roots = ({root.path, root.resolveSymbolicLinksSync()}.toList()
        ..sort((a, b) => b.length.compareTo(a.length)));

  final List<String> _roots;
  final _names = <String, String>{};
  final _backups = <String, String>{};

  /// Names [text]; the first name given to the same bytes stays.
  void name(String text, String label) =>
      _names.putIfAbsent(_key(utf8.encode(text)), () => label);

  /// Lists the kept versions of each document in [relative] (paths from
  /// Documents) under its path rather than its opaque backup id.
  void nameBackups(Iterable<String> relative) {
    for (final path in relative) {
      _backups[backupId(path)] = path;
    }
  }

  /// The name of [bytes], or the start of their hash when nobody named them.
  String of(List<int> bytes) {
    final key = _key(bytes);
    return _names[key] ?? key.substring(0, 12);
  }

  String _key(List<int> bytes) {
    var text = latin1.decode(bytes);
    for (final root in _roots) {
      text = text.replaceAll(latin1.decode(utf8.encode(root)), '<root>');
    }
    return sha256.convert(latin1.encode(text)).toString();
  }
}

/// The folders under Support whose files are journal records.
const journalFolders = {
  'compound-writes',
  'relocation-writes',
  'unfinished-moves',
  'backup-moves',
  'training-writes',
};

/// Everything under [root], as a recovery golden records it: each file by
/// its [labels] name (a folder as `dir`), except the journal records, the
/// records set aside, the reference history and the kept versions, which
/// are listed apart. Records are listed by name alone, since they hold
/// native file identities; times in quarantine and version names are left
/// out.
Map<String, Object?> profileDigest(Directory root, ContentLabels labels) {
  final files = <String, String>{};
  final journal = <String>[];
  final quarantine = <String>[];
  final references = <String, String>{};
  final backups = <String, List<(String, String)>>{};
  final entries = root.listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final parts = p.split(p.relative(entry.path, from: root.path));
    final path = parts.join('/');
    if (entry is! File) {
      if (!_digestedApart(parts)) files[path] = 'dir';
      continue;
    }
    final label = labels.of(entry.readAsBytesSync());
    switch (parts) {
      case ['Support', final folder, ...] when journalFolders.contains(folder):
        journal.add(parts.skip(1).join('/'));
      case ['Support', 'recovery-quarantine', _, ...final name]:
        quarantine.add(name.join('/'));
      case ['Documents', '.cap-reference-history', ...final name]:
        references[name.join('/')] = label;
      case ['Support', 'backups', final id, final name]:
        if (name == 'index.json') continue;
        final version = labels.of(versionBytes(entry.readAsBytesSync()));
        (backups[labels._backups[id] ?? id] ??= []).add((name, version));
      default:
        files[path] = label;
    }
  }
  return {
    'files': files,
    if (journal.isNotEmpty) 'journal': journal,
    if (quarantine.isNotEmpty) 'quarantine': quarantine,
    if (references.isNotEmpty) 'referenceHistory': references,
    if (backups.isNotEmpty)
      'backups': {
        for (final MapEntry(:key, :value) in backups.entries)
          key: [for (final (_, label) in value..sort()) label],
      },
  };
}

bool _digestedApart(List<String> parts) => switch (parts) {
  ['Support', final folder, ...] =>
    journalFolders.contains(folder) ||
        folder == 'recovery-quarantine' ||
        folder == 'backups',
  ['Documents', '.cap-reference-history', ...] => true,
  _ => false,
};

/// Everything the app logs from here until the test ends, so a test can say
/// what a store did and did not report.
List<LogEntry> loggedFromNow() {
  final entries = <LogEntry>[];
  void collect(LogEntry entry) => entries.add(entry);
  log.install(collect);
  addTearDown(() => log.remove(collect));
  return entries;
}

/// A chapter with one game in it, the smallest file a save can name a game
/// of.
String oneGame(String moves) => '[Event "Line"]\n[Result "*"]\n\n$moves *\n';

/// One game of a chapter, numbered so a test can tell them apart.
String gameOf(int number, String moves) =>
    '[Event "Line $number"]\n[Result "*"]\n\n$moves *';

/// A chapter of [games], each on its own with a blank line after it.
String chapterOf(List<String> games) =>
    '$chapterHeading${games.map((game) => '$game\n\n').join()}';

const chapterHeading = '// Main\n// Color: White\n\n';

/// Three games from the initial position, the file the scope tests edit.
final threeGames = chapterOf([
  gameOf(1, '1. d4'),
  gameOf(2, '1. e4'),
  gameOf(3, '1. c4'),
]);

/// [threeGames] with a move added to the first game and the other two left
/// alone: what a save that names game 1 writes.
final firstGameEdited = chapterOf([
  gameOf(1, '1. d4 Nf6'),
  gameOf(2, '1. e4'),
  gameOf(3, '1. c4'),
]);
