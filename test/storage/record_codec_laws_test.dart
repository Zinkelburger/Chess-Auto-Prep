// Laws of the records a restart reads back: a relocation
// journal record decodes to exactly what was encoded, and one of a version
// this build does not know, or with a field it does not know, is refused
// rather than obeyed. A tournament this app saves is read by the old app's
// TimeControl with the same time-control fields.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/storage/backup_relocation.dart';
import 'package:chess_auto_prep/storage/backups.dart';
import 'package:chess_auto_prep/storage/book_references.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/recovery_files.dart';
import 'package:chess_auto_prep/storage/relocation_record.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:chess_auto_prep/storage/training_records.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/gen/csv_gen.dart';
import '../support/gen/json_gen.dart';
import '../support/props.dart';
import 'store_fixture.dart';

final _documents = Directory('/home/u/Documents');
final _support = Directory('/home/u/Support');
final _repertoires = p.join(_documents.path, 'repertoires');

void main() {
  _journalLaws();
  _tournamentLaw();
}

// ---------------------------------------------------------------------------
// Relocation journal records
// ---------------------------------------------------------------------------

/// A record as a move or a delete journals it, and the phase it is in.
typedef _Journaled = ({FileRelocationRecord record, RelocationState phase});

final Generator<_Journaled> _records = Generator((rand) {
  final delete = rand.chance(30);
  final id = delete
      ? '${rand.between(1, 1 << 30)}-${rand.between(1, 1 << 20).toRadixString(16)}'
      : 'move-${rand.between(0, 999)}_${rand.pick(const ['a', 'B', '9'])}';
  final from = p.join(
    _repertoires,
    rand.pick(const ['KID', 'Benko', 'Open, Closed']),
    'Main.pgn',
  );
  final to = delete
      ? p.join(p.dirname(from), '.cap-pgn-history', '$id-${p.basename(from)}')
      : p.join(
          _repertoires,
          rand.pick(const ['Moved', 'Сицилианская']),
          'Main.pgn',
        );
  final books = rand.chance(20) ? null : _books(rand, from);
  return (
    record: FileRelocationRecord(
      id: id,
      kind: delete ? FileRelocationKind.delete : FileRelocationKind.move,
      from: from,
      to: to,
      trainingRoot: _documents.path,
      identity: 'dev:${rand.between(1, 99)}:ino:${rand.between(1, 1 << 30)}',
      hash: List.generate(
        64,
        (_) => rand.pick(const ['0', '7', 'a', 'f']),
      ).join(),
      training: _training(rand, from, to),
      booksBefore: books,
      booksAfter: relocateBookReferences(
        books,
        repertoireRoot: _repertoires,
        from: from,
        to: to,
        directory: false,
        unreadable: (_) {},
      ),
      backup: BackupMove(
        operationId: id,
        rootPath: p.join(_support.path, 'backups'),
        fromId: backupId(p.relative(from, from: _documents.path)),
        toId: backupId(p.relative(to, from: _documents.path)),
        documentPath: to,
      ),
    ),
    phase: rand.pick(RelocationState.values),
  );
});

/// The four training files as a move reads them, rows for [from] among
/// others', and what the move makes of them. A move refuses files with a
/// row it cannot read that may name [from]; those are journaled absent.
TrainingRepointPlan _training(Rand rand, String from, String to) {
  String? file(String text) =>
      rand.chance(20) ? null : text.replaceAll(csvSources.first, from);
  final reviews = reviewCsvs.sample(rand);
  final before = {
    reviewsFile: file(reviews.unclosedLine == null ? reviews.text : ''),
    streaksFile: file(
      '$streaksHeader\n${csvSources.first},line_1,2,1,0\n'
      '${csvSources.last},line_1,0,3,1\n',
    ),
    historyFile: file('$historyHeader\n'),
    attemptsFile: file(
      [
        for (var i = rand.between(0, 3); i > 0; i--)
          attemptLines.sample(rand).line,
      ].join('\n'),
    ),
  };
  TrainingRepointPlan plan(Map<String, String?> files) =>
      TrainingRepointPlan.fromSnapshots(
        from: DocumentRef(from),
        to: DocumentRef(to),
        alternateFrom: DocumentRef(from),
        alternateTo: DocumentRef(to),
        before: files,
      );
  try {
    return plan(before);
  } on Malformed {
    return plan({
      for (final MapEntry(:key, :value) in before.entries)
        key: key == streaksFile ? value : null,
    });
  }
}

/// books.json naming [from] and other chapters, with fields no build knows.
String _books(Rand rand, String from) => jsonEncode(
  withUnknownFields({
    'version': 1,
    'active': 'a',
    'books': [
      {
        'id': 'a',
        'name': 'A',
        'repertoires': ['Benko'],
        'chapters': [
          {'path': p.relative(from, from: _repertoires), 'section': null},
          {'path': 'Else/Main.pgn', 'section': 'Before'},
        ],
      },
    ],
  }, rand),
);

RelocationRecord _decode(Object? json, String id) =>
    RelocationRecord.fromJson(json, id: id, documents: _documents);

void _journalLaws() {
  forAll(
    'a journal record decodes to exactly what was encoded, and still '
    'passes its checks',
    _records,
    (journaled) {
      final (:record, :phase) = journaled;
      final text = jsonEncode(record.toJson(phase));
      final decoded = _decode(jsonDecode(text), record.id);
      expect(jsonEncode(decoded.toJson(phase)), text);
      expect(decoded.state, phase);
      decoded.validate(documents: _documents, support: _support);
    },
    runs: 60,
  );

  forAll(
    'a record of a version this build does not know, or with a field it '
    'does not know, is refused',
    _records,
    (journaled) {
      final (:record, :phase) = journaled;
      final json = record.toJson(phase);
      final rand = Rand(record.id.length);
      for (final version in const [0, 2, 3, 99, '1', 1.5, null]) {
        expect(
          () => _decode({...json, 'version': version}, record.id),
          throwsA(isA<RecoveryRequired>()),
          reason: 'version $version',
        );
      }
      expect(
        () => _decode(withUnknownFields(json, rand, every: true), record.id),
        throwsA(isA<RecoveryRequired>()),
      );
      // One unknown field in one nested object at a time, so each nested
      // check is proven on its own rather than behind the top-level one.
      // The backup plan is BackupMove.fromJson's, which ignores extra keys.
      for (final path in [
        for (final path in jsonPaths(json))
          if (path.length == 2 && path.first == 'training') path,
      ]) {
        final damaged = atPath(json, path, (value) {
          return {...value! as Map<String, Object?>, 'x_0': jsonValue(rand)};
        });
        expect(
          () => _decode(damaged, record.id),
          throwsA(isA<RecoveryRequired>()),
          reason: 'an unknown field under $path',
        );
      }
      expect(
        () => _decode(json, '${record.id}x'),
        throwsA(isA<RecoveryRequired>()),
        reason: 'a record under another name is not this one',
      );
    },
    runs: 30,
  );
}

// ---------------------------------------------------------------------------
// Tournament round trips
// ---------------------------------------------------------------------------

/// Time controls as this app saves them: a preset, or the setup dialog's
/// fields, any of which may be left at its default. The dialog saves sudden
/// death without `movesPerSession`, and a period only when it is positive.
final Generator<Map<String, Object?>> _times = Generator((rand) {
  if (rand.chance(40)) return rand.pick(tournamentTimePresets).time;
  final kind = rand.pick(const [
    'movetime',
    'incremental',
    'fixedDepth',
    'fixedNodes',
  ]);
  Map<String, Object?> maybe(String key, int lo, int hi) =>
      rand.chance(70) ? {key: rand.between(lo, hi)} : const {};
  return {
    'kind': kind,
    ...switch (kind) {
      'incremental' => {
        ...maybe('baseMs', 1, 3600000),
        ...maybe('incrementMs', 0, 60000),
        ...maybe('movesPerSession', 1, 1000),
      },
      'fixedDepth' => maybe('depth', 1, 128),
      'fixedNodes' => maybe('nodes', 1, 2000000000),
      _ => maybe('movetimeMs', 1, 3600000),
    },
  };
});

void _tournamentLaw() {
  forAllAsync(
    'a saved tournament reopens with the '
    'same time-control fields',
    _times,
    (time) async {
      final files = await StoreFixture.create();
      try {
        await _checkTournament(files, time);
      } finally {
        await files.dispose();
      }
    },
    runs: 30,
  );
}

Future<void> _checkTournament(
  StoreFixture files,
  Map<String, Object?> time,
) async {
  final root = Directory(p.join(files.documents.path, 'engine_tournaments'));
  final store = FileTournaments(
    root: root,
    support: files.support,
    documents: files.store,
  );
  final tournament = Tournament({
    'version': 1,
    'id': 'laws',
    'createdAt': '2026-09-29T00:00:00.000Z',
    'status': 'pending',
    'config': {
      'name': 'Match',
      'engines': [
        TournamentEngine.bundled().json,
        TournamentEngine.bundled('Other').json,
      ],
      'timeControl': time,
    },
    'games': <Object>[],
  });
  expect(await store.create(tournament), isA<TournamentSaved<Tournament>>());
  final saved = File(p.join(root.path, 'laws', 'tournament.json'));
  final reopened = Tournament(
    jsonDecode(await saved.readAsString()) as Map<String, Object?>,
  );
  expect(reopened.config.json, tournament.config.json);
  expect(
    reopened.config.timeNumber('movesPerSession', 0),
    greaterThanOrEqualTo(0),
  );
}
