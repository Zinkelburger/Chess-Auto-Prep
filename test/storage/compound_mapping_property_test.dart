// What an unfinished compound edit's references follow, read back from the
// snapshots in its record: the section renames between the books it planned
// from and the books it planned, and the line keys between the training
// files it planned from and the ones it planned. Read back, a plan gives the
// changes it was made from; anything that is not such a plan gives none, so
// recovery never guesses.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/book_references.dart';
import 'package:chess_auto_prep/storage/compound_commit.dart';
import 'package:chess_auto_prep/storage/line_progress.dart';
import 'package:chess_auto_prep/storage/reference_change.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/props.dart';

const _root = '/home/u/Documents/repertoires';
const _files = ['KID/Main.pgn', 'KID/Sub/Lines.pgn', 'Course.pgn'];
const _sections = ['Before', 'Mar del Plata', 'Chapter 1', 'Four Pawns'];

/// Renamed sections are never among the ones renamed, so the renames do not
/// chain.
const _renamedTo = ['After', 'Classical', 'Chapter 2'];

/// A books document with selectors of sections, and renames of sections
/// its selectors name.
typedef _Renamed = ({String books, List<SectionRename> renames});

final _renamed = Generator<_Renamed>((rand) {
  final chapters = [
    for (var i = rand.between(1, 6); i > 0; i--)
      {
        'path': rand.pick(_files),
        'section': rand.chance(20) ? null : rand.pick(_sections),
        if (rand.chance(30)) 'x_pinned': true,
      },
  ];
  final books = jsonEncode({
    'version': 1,
    'active': 'b',
    'books': [
      {
        'id': 'b',
        'name': 'Prep',
        'repertoires': ['KID'],
        'chapters': chapters,
      },
      if (rand.nextBool())
        {'id': 'c', 'name': 'Other', 'chapters': <Object?>[]},
    ],
    if (rand.nextBool()) 'x_sync': {'device': 'laptop'},
  });
  final named = {
    for (final chapter in chapters)
      if (chapter['section'] case final String section)
        (chapter['path']! as String, section),
  }.toList();
  final renames = <SectionRename>[
    for (final (path, section) in named)
      if (rand.chance(60))
        SectionRename(
          path: p.join(_root, path),
          from: section,
          to: rand.pick(_renamedTo),
        ),
  ];
  return (books: books, renames: renames);
});

Set<(String, String, String)> _set(Iterable<SectionRename> renames) => {
  for (final rename in renames) (rename.path, rename.from, rename.to),
};

List<SectionRename>? _between(String? before, String? after) =>
    sectionRenamesBetween(before, after, repertoireRoot: _root);

const _from = '/home/u/Documents/repertoires/KID/Main.pgn';
const _to = '/home/u/Documents/repertoires/KID/Sidelines.pgn';
const _fromAlias = '/data/Documents/repertoires/KID/Main.pgn';
const _toAlias = '/data/Documents/repertoires/KID/Sidelines.pgn';
const _other = '/home/u/Documents/repertoires/Benko/Main.pgn';

/// The four training files, with rows for lines of the source (some named
/// through an alias of Documents), the target and another chapter, and the
/// source lines a move takes to the target under new ids.
typedef _Trained = ({
  Map<String, String> files,
  Map<String, String> ids,
  bool aliased,
});

final _trained = Generator<_Trained>((rand) {
  final aliased = rand.nextBool();
  final keys = [
    for (var i = 0; i < 4; i++)
      (source: aliased && rand.nextBool() ? _fromAlias : _from, id: 'l$i'),
    for (var i = 0; i < 2; i++) (source: _to, id: 'm$i'),
    (source: _other, id: 'l0'),
  ];
  List<LineKey> some() => [
    for (final key in keys)
      if (rand.chance(60)) key,
  ];
  final reviews = some();
  final files = {
    reviewsFile: [
      reviewsHeader,
      for (final key in reviews)
        '${key.source},${key.id},Main,2.5,1,,good,,1,0,false',
    ],
    streaksFile: [
      streaksHeader,
      for (final key in some())
        for (var ply = rand.between(0, 2); ply >= 0; ply--)
          '${key.source},${key.id},$ply,2,true',
    ],
    historyFile: [
      historyHeader,
      for (final key in some())
        for (var n = rand.between(1, 3); n > 0; n--)
          '${key.source},${key.id},2026-09-2${n}T00:00:00Z,good,false,trainer',
    ],
    attemptsFile: [
      for (final key in some())
        jsonEncode({'repertoireId': key.source, 'lineId': key.id, 'ply': 0}),
    ],
  };
  return (
    files: {
      for (final MapEntry(:key, :value) in files.entries)
        key: '${value.join('\n')}\n',
    },
    ids: {
      for (var i = 0; i < 4; i++)
        if (rand.chance(50)) 'l$i': rand.chance(50) ? 'l$i' : 'n$i',
    },
    aliased: aliased,
  );
});

Future<List<CompoundTraining>> _plan(_Trained trained) async {
  final documents = await Directory.systemTemp.createTemp('line-moves-');
  try {
    for (final MapEntry(:key, :value) in trained.files.entries) {
      await File(p.join(documents.path, key)).writeAsString(value);
    }
    return await lineProgressPlan(
      documents,
      from: _from,
      to: _to,
      ids: trained.ids,
      alternateFrom: trained.aliased ? _fromAlias : null,
      alternateTo: trained.aliased ? _toAlias : null,
    );
  } finally {
    await documents.delete(recursive: true);
  }
}

/// The keys [trained] has rows for that its move takes, and where to.
Map<LineKey, LineKey> _moved(_Trained trained) => {
  for (final text in trained.files.values)
    for (final MapEntry(key: id, value: next) in trained.ids.entries)
      for (final (from, to) in [
        (_from, _to),
        if (trained.aliased) (_fromAlias, _toAlias),
      ])
        if (text.contains('$from,$id,') ||
            text.contains('"$from","lineId":"$id"'))
          (source: from, id: id): (source: to, id: next),
};

CompoundTraining _snapshot(
  String name,
  List<String> before,
  List<String> after,
) => CompoundTraining(
  name: name,
  before: '${[headerOf(name), ...before].join('\n')}\n',
  after: '${[headerOf(name), ...after].join('\n')}\n',
);

void main() {
  group('section renames between two books', () {
    forAll('a rename is read back from the books it planned', _renamed, (
      value,
    ) {
      final renamed = renameBookReferences(
        value.books,
        repertoireRoot: _root,
        changes: value.renames,
      );
      expect(_set(_between(value.books, renamed)!), _set(value.renames));
    });

    test('unchanged books rename nothing', () {
      const books = '{"version":1,"books":[]}';
      expect(_between(books, books), isEmpty);
      expect(_between(null, null), isEmpty);
    });

    String books(List<(String, String?)> chapters, {bool other = false}) =>
        jsonEncode({
          'version': 1,
          'books': [
            {
              'id': 'b',
              'name': 'Prep',
              'chapters': [
                for (final (path, section) in chapters)
                  {'path': path, 'section': section},
              ],
            },
            if (other) {'id': 'c', 'name': 'Other'},
          ],
        });

    test('sections swapped cannot be read back', () {
      expect(
        _between(
          books([('Course.pgn', 'A'), ('Course.pgn', 'B')]),
          books([('Course.pgn', 'B'), ('Course.pgn', 'A')]),
        ),
        isNull,
      );
    });

    test('renames that chain cannot be read back', () {
      final before = books([('Course.pgn', 'A'), ('Course.pgn', 'B')]);
      final after = renameBookReferences(
        before,
        repertoireRoot: _root,
        changes: [
          SectionRename(path: p.join(_root, 'Course.pgn'), from: 'B', to: 'C'),
          SectionRename(path: p.join(_root, 'Course.pgn'), from: 'A', to: 'B'),
        ],
      );
      expect(_between(before, after), isNull);
    });

    test('anything else changed cannot be read back', () {
      final before = books([('Course.pgn', 'A')]);
      for (final after in [
        books([('Course.pgn', 'B')], other: true),
        books([('Main.pgn', 'B')]),
        books([('Course.pgn', 'B'), ('Course.pgn', 'B')]),
        books([('Course.pgn', null)]),
        '{"version":1,"books":"not a list"}',
        null,
      ]) {
        expect(_between(before, after), isNull, reason: after);
      }
      // One selector of a section renamed and another left behind.
      expect(
        _between(
          books([('Course.pgn', 'A'), ('Course.pgn', 'A')]),
          books([('Course.pgn', 'B'), ('Course.pgn', 'A')]),
        ),
        isNull,
      );
    });
  });

  group('line moves between two training snapshots', () {
    forAllAsync('a move is read back from the rows it planned', _trained, (
      value,
    ) async {
      expect(lineMovesBetween(await _plan(value)), _moved(value));
    });

    test('moves that chain cannot be read back', () {
      expect(
        lineMovesBetween([
          _snapshot(
            streaksFile,
            ['$_from,a,0,1,true', '$_to,b,0,1,true'],
            ['$_to,b,0,1,true', '$_other,c,0,1,true'],
          ),
        ]),
        isNull,
      );
    });

    test('a line moved to two places cannot be read back', () {
      expect(
        lineMovesBetween([
          _snapshot(
            historyFile,
            [
              '$_from,a,2026-09-21T00:00:00Z,good,false,trainer',
              '$_from,a,2026-09-22T00:00:00Z,good,false,trainer',
            ],
            [
              '$_to,a,2026-09-21T00:00:00Z,good,false,trainer',
              '$_to,b,2026-09-22T00:00:00Z,good,false,trainer',
            ],
          ),
        ]),
        isNull,
      );
    });

    test('a line only partly moved cannot be read back', () {
      expect(
        lineMovesBetween([
          _snapshot(
            streaksFile,
            ['$_from,a,0,1,true', '$_from,a,1,1,true'],
            ['$_to,a,0,1,true', '$_from,a,1,1,true'],
          ),
        ]),
        isNull,
      );
    });

    test('a row whose other cells changed cannot be read back', () {
      expect(
        lineMovesBetween([
          _snapshot(streaksFile, ['$_from,a,0,1,true'], ['$_to,a,0,2,true']),
        ]),
        isNull,
      );
      expect(
        lineMovesBetween([
          const CompoundTraining(
            name: attemptsFile,
            before: '{"repertoireId":"$_from","lineId":"a","ply":0}\n',
            after: '{"repertoireId":"$_to","lineId":"a","ply":1}\n',
          ),
        ]),
        isNull,
      );
    });

    test('a file that appeared or went away cannot be read back', () {
      expect(
        lineMovesBetween([
          const CompoundTraining(name: reviewsFile, before: null, after: 'x'),
        ]),
        isNull,
      );
      expect(
        lineMovesBetween([
          const CompoundTraining(name: reviewsFile, before: null, after: null),
        ]),
        isEmpty,
      );
    });
  });
}
