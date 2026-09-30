// What recovery does today, pinned so a change to it can show it changes
// nothing it did not mean to. Each scenario stops a journalled command at
// one of its steps (or lets it finish), disturbs the profile the way the
// user or another app might, starts the app again once or twice, and
// records what the profile then holds ([profileDigest]): the files that
// differ from the seed, the journal, the records set aside, the reference
// history and the kept versions. The records are the goldens under
// fixtures/recovery_matrix, one file per kind of command.
//
// UPDATE_RECOVERY_MATRIX=1 records the goldens again. A recorded outcome
// may change only when [_allowedChanges] names its scenario and the finding
// the change fixes; any other difference fails, under UPDATE too.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/compound_commit.dart';
import 'package:chess_auto_prep/storage/compound_write.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/file_relocation.dart';
import 'package:chess_auto_prep/storage/operation_journal.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:chess_auto_prep/storage/training_writes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

final _update = Platform.environment['UPDATE_RECOVERY_MATRIX'] == '1';

/// Recorded outcomes a fix may change, each naming the finding it fixes. A
/// key is `kind/step/disturbance/restarts`, where `*` stands for any one
/// part. Entries stay, as the record of why an outcome changed.
final _allowedChanges = <String, String>{
  'relocation-folder/intent/chmodOnce/*': _unreadableInventory,
  'relocation-folder/intent/chmodAlways/*': _unreadableInventory,
  for (final step in ['intent', 'document', 'training', 'books']) ...{
    'compound-v1/$step/pivot2Edited/*': _replannedSelectors,
    'compound-v1/$step/unrelatedBook/*': _replannedSelectors,
  },
  'compound-v1/intent/booksNotBooks/*': _booksNotFollowed,
  for (final step in ['document', 'secondaryDocument', 'training'])
    'compound-v2/$step/pivot2Edited/*': _putBack,
  for (final step in ['document', 'secondaryDocument'])
    'compound-v3/$step/pivot2Edited/*': _putBack,
  for (final step in ['intent', 'document', 'secondaryDocument', 'training'])
    'compound-v3/$step/trainingRowAdded/*': _replannedRows,
  for (final kind in [
    'relocation-move',
    'relocation-delete',
    'relocation-folder',
  ])
    for (final step in FileRelocationStep.values)
      if (step != FileRelocationStep.prepared)
        '$kind/${step.name}/*/*': _unfinished,
};

const _unreadableInventory =
    'A folder move not yet landed checked its inventory with '
    'DirectorySnapshot.verify, which turned a file it could not read for '
    'now into RecoveryRequired, so the record was set aside; it is now kept '
    'and finished once the file can be read.';

const _replannedSelectors =
    'A section rename whose books.json another writer changed was set aside '
    'whole, even when only another book or key was added; its selectors are '
    'now renamed again in the books as they are, and the rename finishes.';

const _booksNotFollowed =
    'A section rename whose books.json was replaced by something that is not '
    'a books document was set aside before its PGN was renamed; books never '
    'stop an edit now, so the PGN is renamed, books.json is left as it is and '
    'the record is kept in quarantine.';

const _putBack =
    'A line move whose target another writer changed was set aside with its '
    'source already rewritten, so the moved lines were in neither file; the '
    'source is now put back to its exact bytes, what the move wrote there '
    'kept as a version, before the record is set aside. A move without '
    'training cannot tell whether the target was changed after the move had '
    'finished, so the lines may be in both.';

const _unfinished =
    'A move stopped once its record was written was answered as a failure '
    'like one that wrote nothing, so the exit prompt asked about it although '
    'recovery finishes it; it is now answered Unfinished (FolderMoveUnfinished '
    'for a folder), which still extends the failure. What the profile holds '
    'is unchanged.';

const _replannedRows =
    'A line move whose training files another writer changed (an answer '
    'written meanwhile) was set aside; its rows are now moved again in the '
    'files as they are, and the move finishes.';

/// What happens to the profile between the stopped command and the restart.
enum Disturbance {
  none,

  /// The first participant, or a file at its path, edited elsewhere.
  pivot1Edited,
  pivot2Edited,

  /// A review row added for the line the command moves, at its old path.
  trainingRowAdded,

  /// Another book added to books.json.
  unrelatedBook,

  /// books.json replaced by JSON that is not a books document.
  booksNotBooks,

  /// A participant unreadable for the first restart only.
  chmodOnce,

  /// A participant unreadable through every restart.
  chmodAlways,
}

final class _Kind {
  const _Kind(this.name, this.steps, this.pivots, this.command);
  final String name;
  final List<Enum> steps;

  /// The two participants a disturbance edits, from the profile root.
  final (String, String) pivots;

  /// Runs the command, stopping at the step named, and says how it ended.
  final Future<String> Function(_Profile profile, String? stop) command;
}

const _a = 'Documents/repertoires/KID/A.pgn';
const _b = 'Documents/repertoires/KID/B.pgn';
const _c = 'Documents/repertoires/KID/C.pgn';
const _other = 'Documents/repertoires/Other.pgn';
const _deleted = 'Documents/repertoires/KID/.cap-pgn-history/1-abc-A.pgn';
const _inFolder = 'Documents/repertoires/KID2/A.pgn';
const _books = 'Support/books.json';
const _reviews = 'Documents/$reviewsFile';

const _kinds = [
  _Kind('compound-v1', CompoundWriteStep.values, (_a, _books), _sectionRename),
  _Kind('compound-v2', CompoundWriteStep.values, (_a, _b), _linePair),
  _Kind('compound-v3', CompoundWriteStep.values, (_a, _b), _trainedPair),
  _Kind('relocation-move', FileRelocationStep.values, (_a, _c), _move),
  _Kind('relocation-delete', FileRelocationStep.values, (
    _a,
    _deleted,
  ), _delete),
  _Kind('relocation-folder', FileRelocationStep.values, (
    _a,
    _inFolder,
  ), _moveFolder),
  _Kind('training-answer', TrainingWriteStep.values, (_a, _reviews), _answer),
];

const _line1 =
    '[Event "Line 1"]\n[ChapterName "Before"]\n[Result "*"]\n\n1. d4 *\n';
const _line3 =
    '[Event "Line 3"]\n[ChapterName "Before"]\n[Result "*"]\n\n1. c4 *\n';
const _aBefore = '$_line1\n$_line3';
final _aRenamed = _aBefore.replaceAll('"Before"', '"After"');
const _bBefore = '[Event "Line 2"]\n[Result "*"]\n\n1. e4 *\n';
const _bReceived = '$_bBefore\n$_line3';
const _otherText = '[Event "Other"]\n[Result "*"]\n\n1. Nf3 *\n';
const _elsewhere = '[Event "Edited elsewhere"]\n[Result "*"]\n\n1. a3 *\n';

final class _Profile {
  _Profile(this.fixture) : labels = ContentLabels(fixture.root);
  final StoreFixture fixture;
  final ContentLabels labels;

  String path(String relative) =>
      p.join(fixture.root.path, p.joinAll(relative.split('/')));

  Future<void> write(String relative, String text, String label) async {
    labels.name(text, label);
    final file = File(path(relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  /// What [relative] holds and its label; no text and `new` when absent.
  (String?, String) read(String relative) {
    final file = File(path(relative));
    if (!file.existsSync()) return (null, 'new');
    final bytes = file.readAsBytesSync();
    return (utf8.decode(bytes), labels.of(bytes));
  }

  /// Changes [relative] the way another app would, or puts a file there.
  Future<void> edit(String relative) async {
    final (text, label) = read(relative);
    final edited = switch (p.extension(relative)) {
      '.json' => jsonEncode({
        ...jsonDecode(text ?? '{}') as Map<String, Object?>,
        'edited': true,
      }),
      '.csv' =>
        '${text ?? '$reviewsHeader\n'}${_review(path(_other), 'edited')}',
      _ => text == null ? _elsewhere : '$text\n$_elsewhere',
    };
    await write(relative, edited, '$label+edited');
  }
}

String _review(String chapter, String line) =>
    '$chapter,$line,Main,2.5,1,2026-09-01T00:00:00Z,good,'
    '2026-08-31T00:00:00Z,2,0,false\n';

/// The four training files with rows for the line in [chapter], and a
/// review of a chapter no command touches.
Map<String, String> _training(_Profile profile, String chapter) {
  final path = profile.path(chapter);
  final attempt = Attempt(
    key: (source: path, id: 'line'),
    ply: 0,
    fen: Fen.initial,
    played: 'd4',
    expected: 'd4',
    correct: true,
    phase: AttemptPhase.drilling,
    at: DateTime.utc(2026, 8, 31),
  );
  return {
    reviewsFile:
        '$reviewsHeader\n${_review(path, 'line')}'
        '${_review(profile.path(_other), 'line')}',
    streaksFile: '$streaksHeader\n$path,line,1,2,true\n',
    historyFile:
        '$historyHeader\n$path,line,2026-08-31T00:00:00Z,good,false,trainer\n',
    attemptsFile: '${encodeAttempt(attempt)}\n',
  };
}

const _short = {
  reviewsFile: 'reviews',
  streaksFile: 'streaks',
  historyFile: 'history',
  attemptsFile: 'attempts',
};

String _bookList(String chapter, String? section) => jsonEncode({
  'version': 1,
  'books': [
    {
      'id': 'book',
      'name': 'Book',
      'repertoires': <String>[],
      'chapters': [
        {'path': chapter, 'section': section},
        {'path': 'Other.pgn', 'section': null},
      ],
    },
  ],
  'unknown': 'kept',
});

/// The profile every scenario starts from, with names for what each
/// command is expected to write.
Future<void> _seed(_Profile profile) async {
  await profile.write(_a, _aBefore, 'A:before');
  await profile.write(_b, _bBefore, 'B:before');
  await profile.write(_other, _otherText, 'Other');
  await profile.write(_books, _bookList('KID/A.pgn', 'Before'), 'books:before');
  for (final MapEntry(:key, :value) in _training(profile, _a).entries) {
    await profile.write('Documents/$key', value, '${_short[key]}:before');
  }
  final labels = profile.labels
    ..name(_aRenamed, 'A:renamed')
    ..name(_line1, 'A:kept')
    ..name(_bReceived, 'B:received')
    ..name(_bookList('KID/A.pgn', 'After'), 'books:renamed')
    ..nameBackups([
      for (final path in [_a, _b, _c, _deleted, _inFolder])
        p.posix.relative(path, from: 'Documents'),
    ]);
  for (final (chapter, books, name) in [
    (_b, null, 'B'),
    (_c, 'KID/C.pgn', 'C'),
    (_deleted, 'KID/.cap-pgn-history/1-abc-A.pgn', 'deleted'),
    (_inFolder, 'KID2/A.pgn', 'KID2'),
  ]) {
    for (final MapEntry(:key, :value) in _training(profile, chapter).entries) {
      labels.name(value, '${_short[key]}:$name');
    }
    if (books != null) labels.name(_bookList(books, 'Before'), 'books:$name');
  }
}

CompoundWrites _compounds(_Profile profile, String? stop) => CompoundWrites(
  documents: profile.fixture.documents,
  support: profile.fixture.support,
  testHook: stopOnceAt(stop),
);

/// How a commit ended, in the words the goldens were recorded in: a commit
/// then threw at a stop instead of answering a [Settlement].
String _committed(Settlement settlement) =>
    settlement is Finished ? 'committed' : 'threw StateError';

Future<String> _sectionRename(_Profile profile, String? stop) async {
  final settlement = await _compounds(profile, stop).commit(
    CompoundCommit(
      id: 'rename-1',
      documentPath: profile.path(_a),
      documentBefore: _aBefore,
      documentAfter: _aRenamed,
      booksBefore: _bookList('KID/A.pgn', 'Before'),
      booksAfter: _bookList('KID/A.pgn', 'After'),
    ),
  );
  return _committed(settlement);
}

Future<String> _linePair(_Profile profile, String? stop) =>
    _pair(profile, stop, 'pair-2', const []);

Future<String> _trainedPair(_Profile profile, String? stop) {
  final before = _training(profile, _a);
  final after = _training(profile, _b);
  return _pair(profile, stop, 'pair-3', [
    for (final name in [reviewsFile, streaksFile, historyFile, attemptsFile])
      CompoundTraining(name: name, before: before[name], after: after[name]),
  ]);
}

Future<String> _pair(
  _Profile profile,
  String? stop,
  String id,
  List<CompoundTraining> training,
) async {
  final settlement = await _compounds(profile, stop).commit(
    CompoundCommit.pair(
      id: id,
      primary: CompoundDocument(
        path: profile.path(_a),
        before: _aBefore,
        after: _line1,
      ),
      secondary: CompoundDocument(
        path: profile.path(_b),
        before: _bBefore,
        after: _bReceived,
      ),
      training: training,
    ),
  );
  return _committed(settlement);
}

FileRelocations _relocations(_Profile profile, String? stop) => FileRelocations(
  documents: profile.fixture.documents,
  support: profile.fixture.support,
  testHook: stopOnceAt(stop),
);

Future<String> _move(_Profile profile, String? stop) async {
  final from = DocumentRef(profile.path(_a));
  final result = await _relocations(profile, stop).move(
    from,
    DocumentRef(profile.path(_c)),
    expected: await profile.fixture.revisionOf(from),
    operationId: 'move-1',
  );
  return '${result.runtimeType}';
}

Future<String> _delete(_Profile profile, String? stop) async {
  final from = DocumentRef(profile.path(_a));
  final result = await _relocations(profile, stop).delete(
    from,
    expected: await profile.fixture.revisionOf(from),
    operationId: '1-abc',
  );
  return '${result.runtimeType}';
}

Future<String> _moveFolder(_Profile profile, String? stop) async {
  final result = await _relocations(profile, stop).moveFolder(
    p.dirname(profile.path(_a)),
    p.dirname(profile.path(_inFolder)),
    operationId: 'folder-1',
  );
  return '${result.runtimeType}';
}

RecoveryGate _gate(_Profile profile) => RecoveryGate(
  documents: profile.fixture.documents,
  support: profile.fixture.support,
  retryDelay: Duration.zero,
);

/// A rating of a new line in A: a review, a streak and a history row.
Future<String> _answer(_Profile profile, String? stop) async {
  final store = TrainingStore(
    profile.fixture.documents,
    support: profile.fixture.support,
    trainingHook: stopOnceAt(stop),
    recovery: _gate(profile),
  );
  final source = profile.path(_a);
  final loaded = await store.read({source});
  if (loaded is! ProgressLoaded) return '${loaded.runtimeType}';
  final key = (source: source, id: 'line2');
  final at = DateTime.utc(2026, 9, 1);
  final result = await store.write(
    reviews: [
      (
        before: null,
        after: Review(key: key, lineName: 'Second', lastRating: 'good'),
      ),
    ],
    streaks: [
      (
        before: null,
        after: MoveStreak(key: key, ply: 0, streak: 1, learned: false),
      ),
    ],
    history: [
      HistoryRow(
        key: key,
        at: at,
        rating: 'good',
        mistake: false,
        kind: HistoryKind.trainer,
      ),
    ],
    operation: ProgressOperation(id: 'answer-1', sources: loaded.sources),
  );
  return '${result.runtimeType}';
}

Future<void> _disturb(
  _Profile profile,
  _Kind kind,
  Disturbance disturbance,
) async {
  switch (disturbance) {
    case Disturbance.pivot1Edited:
      await profile.edit(kind.pivots.$1);
    case Disturbance.pivot2Edited:
      await profile.edit(kind.pivots.$2);
    case Disturbance.trainingRowAdded:
      final (text, label) = profile.read(_reviews);
      await profile.write(
        _reviews,
        '${text ?? '$reviewsHeader\n'}${_review(profile.path(_a), 'added')}',
        '$label+row',
      );
    case Disturbance.unrelatedBook:
      final (text, label) = profile.read(_books);
      final json = jsonDecode(text!) as Map<String, Object?>;
      final books = [
        ...json['books']! as List<Object?>,
        {
          'id': 'unrelated',
          'name': 'Unrelated',
          'repertoires': <String>[],
          'chapters': [
            {'path': 'Other.pgn', 'section': null},
          ],
        },
      ];
      await profile.write(
        _books,
        jsonEncode({...json, 'books': books}),
        '$label+book',
      );
    case Disturbance.booksNotBooks:
      await profile.write(_books, '[]', 'not-books');
    case Disturbance.none || Disturbance.chmodOnce || Disturbance.chmodAlways:
      break;
  }
}

/// Takes access to the first pivot there away, and answers its path.
Future<String?> _lock(_Profile profile, _Kind kind) async {
  for (final relative in [kind.pivots.$1, kind.pivots.$2]) {
    final path = profile.path(relative);
    if (File(path).existsSync()) {
      await Process.run('chmod', ['000', path]);
      return path;
    }
  }
  return null;
}

/// Runs [body] without the warnings recovery prints.
Future<T> _quietly<T>(Future<T> Function() body) => runZoned(
  body,
  zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
);

/// A new session's first access, which finishes what the last one left.
Future<String?> _restart(_Profile profile) async {
  try {
    await _gate(profile).run(() async {});
    return null;
  } on Object catch (error) {
    return 'threw ${error.runtimeType}';
  }
}

Future<Map<String, Object?>> _outcome(
  _Kind kind,
  String step,
  Disturbance disturbance,
  int restarts,
) async {
  final profile = _Profile(await StoreFixture.create());
  try {
    await _seed(profile);
    final seed = profileDigest(profile.fixture.root, profile.labels);
    final command = await _quietly(() async {
      try {
        return await kind.command(profile, step == 'none' ? null : step);
      } on Object catch (error) {
        return 'threw ${error.runtimeType}';
      }
    });
    await _disturb(profile, kind, disturbance);
    final locked = switch (disturbance) {
      Disturbance.chmodOnce ||
      Disturbance.chmodAlways => await _lock(profile, kind),
      _ => null,
    };
    final failures = <String>[];
    for (var i = 0; i < restarts; i++) {
      if (await _quietly(() => _restart(profile)) case final failure?) {
        failures.add(failure);
      }
      final last = i == restarts - 1;
      if (locked != null && (last || disturbance == Disturbance.chmodOnce)) {
        await Process.run('chmod', ['644', locked]);
      }
    }
    final digest = profileDigest(profile.fixture.root, profile.labels);
    return {
      'command': command,
      if (failures.isNotEmpty) 'restarts': failures,
      ...digest,
      'files': _changed(seed['files']! as Map, digest['files']! as Map),
    };
  } finally {
    await profile.fixture.dispose();
  }
}

/// The entries of [now] that differ from [seed]; one gone reads `missing`.
Map<String, Object?> _changed(
  Map<Object?, Object?> seed,
  Map<Object?, Object?> now,
) => {
  for (final path in ({...seed.keys, ...now.keys}.toList()..sort()))
    if (seed[path] != now[path]) '$path': now[path] ?? 'missing',
};

File _golden(String kind) => File(
  p.join('test', 'storage', 'fixtures', 'recovery_matrix', '$kind.json'),
);

Map<String, Object?> _readGolden(String kind) {
  final file = _golden(kind);
  if (!file.existsSync()) return const {};
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// One scenario per line, so a changed outcome is a one-line diff.
Future<void> _writeGolden(String kind, Map<String, Object?> outcomes) async {
  final keys = outcomes.keys.toList()..sort();
  final lines = [
    for (final key in keys)
      '  ${jsonEncode(key)}: ${jsonEncode(outcomes[key])}',
  ];
  final file = _golden(kind);
  await file.parent.create(recursive: true);
  await file.writeAsString('{\n${lines.join(',\n')}\n}\n');
}

/// The finding [_allowedChanges] names for [key], if any.
String? _allowed(String key) {
  final parts = key.split('/');
  for (final MapEntry(key: pattern, value: finding)
      in _allowedChanges.entries) {
    final wanted = pattern.split('/');
    if (wanted.length == parts.length &&
        Iterable<int>.generate(
          parts.length,
        ).every((i) => wanted[i] == '*' || wanted[i] == parts[i])) {
      return finding;
    }
  }
  return null;
}

List<(String, String, Disturbance, int)> _scenarios(_Kind kind) => [
  for (final step in ['none', for (final step in kind.steps) step.name])
    for (final disturbance in Disturbance.values)
      for (final restarts in [1, 2])
        (
          '${kind.name}/$step/${disturbance.name}/$restarts',
          step,
          disturbance,
          restarts,
        ),
];

final _noChmod =
    Platform.isWindows ||
        (Process.runSync('id', ['-u']).stdout as String).trim() == '0'
    ? 'chmod cannot take access away here'
    : null;

/// Unnamed texts are hashed with their native path separators, so the
/// goldens only hold where they were recorded.
const _linuxOnly = 'the goldens are recorded on Linux';

void main() {
  for (final kind in _kinds) {
    final golden = _readGolden(kind.name);
    final recorded = Map<String, Object?>.of(golden);
    group(kind.name, () {
      for (final (key, step, disturbance, restarts) in _scenarios(kind)) {
        final chmod = disturbance.name.startsWith('chmod');
        test(key, () async {
          final actual = jsonDecode(
            jsonEncode(await _outcome(kind, step, disturbance, restarts)),
          );
          final before = golden[key];
          if (before == null || _allowed(key) != null) {
            recorded[key] = actual;
            if (_update) return;
          }
          expect(
            actual,
            before,
            reason:
                'Recovery now ends $key differently. If a fix meant this, '
                'name the scenario and the finding in _allowedChanges and '
                'record it with UPDATE_RECOVERY_MATRIX=1.',
          );
        }, skip: chmod && _noChmod != null ? _noChmod : false);
      }
      test('every recorded scenario still runs', () {
        final keys = {for (final s in _scenarios(kind)) s.$1};
        expect(
          golden.keys.where(
            (key) => !keys.contains(key) && _allowed(key) == null,
          ),
          isEmpty,
        );
      });
      if (_update) {
        tearDownAll(() {
          final keys = {for (final s in _scenarios(kind)) s.$1};
          recorded.removeWhere(
            (key, _) => !keys.contains(key) && _allowed(key) != null,
          );
          return _writeGolden(kind.name, recorded);
        });
      }
    }, skip: Platform.isLinux ? false : _linuxOnly);
  }

  test('every allowed change names a scenario and a finding', () {
    final keys = [
      for (final kind in _kinds) ..._scenarios(kind).map((s) => s.$1),
    ];
    for (final MapEntry(:key, :value) in _allowedChanges.entries) {
      expect(value.trim(), isNotEmpty, reason: key);
      expect(
        keys.where((scenario) => _allowed(scenario) == value),
        isNotEmpty,
        reason: key,
      );
    }
  });
}
