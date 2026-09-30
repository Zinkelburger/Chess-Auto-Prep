// Laws of books.json over generated documents: the two reference rewrites
// change only the selectors they name and keep every other field, unknown
// ones included; applying one twice is applying it once, and its inverse
// gives the document back. BookList reads what the strict reader accepts the
// same way, and a write through BookFile never loses what BookList could not
// read: a copy of the old bytes is kept.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/book_file.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/book_references.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:chess_auto_prep/storage/reference_change.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/gen/json_gen.dart';
import '../support/props.dart';

const _root = '/home/u/Documents/repertoires';

const _folders = ['KID', 'KID/Sub', 'Benko', 'Open, Closed', 'Документы'];
const _files = [
  'KID/Main.pgn',
  'KID/Sub/Lines.pgn',
  'Benko/Main.pgn',
  'Open, Closed/Main.pgn',
  'Course.pgn',
];
const _sections = ['Before', 'After', 'Chapter 1', ''];

/// A books document and what was done to it that BookList cannot keep.
final class _Books {
  _Books(
    this.json, {
    required this.lossy,
    required this.text,
    required this.seed,
  });

  final Map<String, Object?> json;

  /// For the edit a law makes to it.
  final int seed;

  /// Unknown fields, repeated selectors, an active book that is not one:
  /// anything a BookList written back loses.
  final bool lossy;

  /// The bytes on disk: pretty or compact, now and then after a BOM.
  final String text;

  @override
  String toString() => text;
}

/// Documents the strict reader accepts, as BookList writes them or as a
/// newer build or a hand edit leaves them, [marked] percent of them after a
/// byte-order mark.
Generator<_Books> _documentsMarked(int marked) => Generator((rand) {
  final canonical = rand.chance(25);
  final books = [
    for (var i = rand.between(0, 3); i > 0; i--) _book(rand, 'b$i', canonical),
  ];
  // An active book that is not in the list is read as none.
  final dangling = !canonical && rand.chance(15);
  final active = dangling
      ? 'nobody'
      : books.isEmpty || rand.chance(25)
      ? null
      : rand.pick(books)['id'];
  var lossy = dangling;
  Object? json = <String, Object?>{
    'version': 1,
    if (canonical || rand.chance(70)) 'active': active,
    'books': books,
  };
  if (canonical) {
    json = jsonDecode(BookList.decode(jsonEncode(json)).encode());
  } else {
    lossy = lossy || books.any(_repeats);
    if (rand.chance(60)) {
      final known = json;
      json = withUnknownFields(json, rand);
      // An object may be left without, so there may be none to lose.
      lossy = lossy || !sameJson(json, known);
    }
  }
  final encoded = canonical || rand.nextBool()
      ? const JsonEncoder.withIndent('  ').convert(json)
      : jsonEncode(json);
  return _Books(
    json! as Map<String, Object?>,
    lossy: lossy,
    text: '${rand.chance(marked) ? '\ufeff' : ''}$encoded',
    seed: rand.between(0, 1 << 30),
  );
});

final _documents = _documentsMarked(0);

/// As a hand edit in some editors saves it.
final _marked = _documentsMarked(100);

/// As BookFile may find it on disk.
final _stored = _documentsMarked(15);

Map<String, Object?> _book(Rand rand, String id, bool canonical) => {
  'id': id,
  'name': rand.pick(const ['Spring', 'Open, Closed', 'Турнир', '']),
  if (canonical || rand.chance(80))
    'repertoires': [
      for (var i = rand.between(0, 3); i > 0; i--)
        rand.pick(rand.chance(70) ? _folders : _files),
    ],
  if (canonical || rand.chance(80))
    'chapters': [
      for (var i = rand.between(0, 4); i > 0; i--)
        {
          'path': rand.pick(_files),
          if (canonical || rand.chance(80))
            'section': rand.chance(30) ? null : rand.pick(_sections),
        },
    ],
};

bool _repeats(Map<String, Object?> book) {
  final folders = book['repertoires'] as List<Object?>? ?? const [];
  final chapters = [
    for (final c in book['chapters'] as List<Object?>? ?? const [])
      jsonEncode([(c! as Map)['path'], c['section']]),
  ];
  return folders.toSet().length != folders.length ||
      chapters.toSet().length != chapters.length;
}

String _json(String text) =>
    text.startsWith('\ufeff') ? text.substring(1) : text;

void main() {
  _renameLaws();
  test('a rename outside the repertoires folder never reads the file', () {
    const damaged = '{"version": 1, "books": "not a list"';
    final changes = [
      SectionRename(path: '/elsewhere/${_files.first}', from: 'A', to: 'B'),
    ];
    expect(
      renameBookReferences(damaged, repertoireRoot: _root, changes: changes),
      damaged,
    );
  });
  _relocateLaws();
  _markedLaws();
  _bookListLaws();
}

void _renameLaws() {
  forAll(
    'a section rename changes only the selectors it names',
    _documents,
    _checkRename,
  );

  forAll(
    'a section rename applied twice is applied once, and undone by '
    'its reverse',
    _documents,
    _checkRenameTwice,
  );
}

void _checkRename(_Books books) {
  final rand = Rand(books.seed);
  final changes = [
    for (var i = rand.between(1, 2); i > 0; i--)
      SectionRename(
        path: p.join(_root, rand.pick(_files)),
        from: rand.pick(_sections),
        to: rand.pick(_sections),
      ),
  ];
  final renamed = renameBookReferences(
    books.text,
    repertoireRoot: _root,
    changes: changes,
  );
  final expected = _renamedByHand(books.json, changes);
  if (sameJson(expected, books.json)) {
    expect(renamed, books.text, reason: 'no match gives the bytes back');
  } else {
    expect(sameJson(jsonDecode(_json(renamed!)), expected), isTrue);
    _expectSameMark(renamed, books.text);
  }
}

void _checkRenameTwice(_Books books) {
  final rand = Rand(books.seed);
  final path = p.join(_root, rand.pick(_files));
  final from = rand.pick(_sections);
  final to = rand.pick([..._sections]..remove(from));
  String? rename(String? text, String a, String b) => renameBookReferences(
    text,
    repertoireRoot: _root,
    changes: [SectionRename(path: path, from: a, to: b)],
  );
  final once = rename(books.text, from, to);
  expect(rename(once, from, to), once);
  if (_sectionsAt(books.json, path).contains(to)) return;
  expect(sameJson(jsonDecode(rename(once, to, from)!), books.json), isTrue);
}

/// [json] as [changes] should leave it, applied in order to every chapter
/// selector whose path and section they name.
Object? _renamedByHand(Map<String, Object?> json, List<SectionRename> changes) {
  final copy = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  for (final book in copy['books']! as List<Object?>) {
    for (final chapter in (book! as Map)['chapters'] as List? ?? const []) {
      final selector = chapter as Map<String, Object?>;
      final before = selector['section'];
      final after = changes.fold(
        before,
        (section, change) =>
            p.join(_root, selector['path']! as String) == change.path &&
                section == change.from
            ? change.to
            : section,
      );
      if (after != before) selector['section'] = after;
    }
  }
  return copy;
}

Set<Object?> _sectionsAt(Map<String, Object?> json, String path) => {
  for (final book in json['books']! as List<Object?>)
    for (final chapter in (book! as Map)['chapters'] as List? ?? const [])
      if (p.join(_root, (chapter as Map)['path'] as String) == path)
        chapter['section'],
};

/// A move of a file or folder the books may name to a place none of them
/// names yet.
typedef _Move = ({String from, String to, bool directory});

_Move _move(Rand rand) => rand.nextBool()
    ? (
        from: p.join(_root, rand.pick(_files)),
        to: p.join(_root, rand.pick(const ['Moved.pgn', 'New/Main.pgn'])),
        directory: false,
      )
    : (
        from: p.join(_root, rand.pick(_folders)),
        to: p.join(_root, rand.pick(const ['Moved', 'New/Place'])),
        directory: true,
      );

String? _relocate(String? text, String from, String to, bool directory) =>
    relocateBookReferences(
      text,
      repertoireRoot: _root,
      from: from,
      to: to,
      directory: directory,
    );

void _markedLaws() {
  forAll(
    'a books.json after a byte-order mark is renamed like any other',
    _marked,
    _checkRename,
  );
  forAll(
    'a books.json after a byte-order mark follows a move like any other',
    _marked,
    _checkMove,
  );
}

void _relocateLaws() {
  forAll(
    'a move changes only the selectors at or under what moved',
    _documents,
    _checkMove,
  );

  forAll(
    'a move applied twice is applied once, and undone by its reverse',
    _documents,
    (books) {
      final (:from, :to, :directory) = _move(Rand(books.seed));
      final once = _relocate(books.text, from, to, directory);
      expect(_relocate(once, from, to, directory), once);
      final back = _relocate(once, to, from, directory);
      expect(sameJson(jsonDecode(back!), books.json), isTrue);
    },
  );
}

void _checkMove(_Books books) {
  final move = _move(Rand(books.seed));
  final moved = _relocate(books.text, move.from, move.to, move.directory);
  final expected = _movedByHand(books.json, move);
  if (sameJson(expected, books.json)) {
    expect(moved, books.text, reason: 'no match gives the bytes back');
  } else {
    expect(sameJson(jsonDecode(_json(moved!)), expected), isTrue);
    _expectSameMark(moved, books.text);
  }
}

/// A rewrite keeps a byte-order mark the original had and adds none.
void _expectSameMark(String rewritten, String original) => expect(
  rewritten.startsWith('\ufeff'),
  original.startsWith('\ufeff'),
  reason: 'a rewrite keeps the byte-order mark as it was',
);

/// [json] with every selector at [move]'s source, or under it for a folder,
/// pointing at its destination instead.
Object? _movedByHand(Map<String, Object?> json, _Move move) {
  final before = p.relative(move.from, from: _root);
  final after = p.relative(move.to, from: _root);
  Object? moved(Object? path) => path is! String || !isBookSelector(path)
      ? path
      : path == before
      ? after
      : move.directory && p.posix.isWithin(before, path)
      ? p.posix.join(after, p.posix.relative(path, from: before))
      : path;
  final copy = jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  for (final book in copy['books']! as List<Object?>) {
    final entry = book! as Map<String, Object?>;
    if (entry['repertoires'] case final List<Object?> folders) {
      entry['repertoires'] = folders.map(moved).toList();
    }
    for (final chapter in entry['chapters'] as List? ?? const []) {
      final selector = chapter as Map<String, Object?>;
      selector['path'] = moved(selector['path']);
    }
  }
  return copy;
}

void _bookListLaws() {
  forAll(
    'BookList reads what the strict reader accepts the same way',
    _stored,
    (books) {
      final text = _json(books.text);
      final strict = readBookDocument(text)!;
      final list = BookList.decode(text);
      final entries = strict['books']! as List<Object?>;
      expect(list.books.map((b) => b.id), [
        for (final b in entries) (b! as Map)['id'],
      ]);
      for (final (i, book) in list.books.indexed) {
        final json = entries[i]! as Map<String, Object?>;
        expect(book.name, json['name']);
        expect(book.repertoires, (json['repertoires'] as List? ?? []).toSet());
        expect(book.chapters, {
          for (final c in json['chapters'] as List? ?? const [])
            BookChapter((c as Map)['path'] as String, c['section'] as String?),
        });
      }
      final active = strict['active'];
      expect(
        list.active,
        list.books.any((b) => b.id == active) ? active : null,
      );
      final again = BookList.decode(list.encode());
      expect(readBookDocument(list.encode()), isNotNull);
      expect(again.encode(), list.encode());
    },
  );

  forAllAsync(
    'a write through BookFile keeps a copy of any file it would lose '
    'something of, and only then',
    _stored,
    (books) async {
      final root = await Directory.systemTemp.createTemp('books-laws-');
      try {
        await _checkWriteKeeps(root, books);
      } finally {
        await root.delete(recursive: true);
      }
    },
    runs: 40,
  );
}

Future<void> _checkWriteKeeps(Directory root, _Books books) async {
  final support = Directory(p.join(root.path, 'Support'));
  final file = File(p.join(support.path, 'books.json'));
  await file.create(recursive: true);
  await file.writeAsBytes(utf8.encode(books.text));
  final store = BookFile(
    support,
    recovery: RecoveryGate(
      documents: Directory(p.join(root.path, 'Documents')),
      support: support,
    ),
  );
  final read = await store.read();
  final next = BookList(
    books: [
      ...read.books,
      const Book(id: 'new', name: 'Added'),
    ],
    active: read.active,
  );
  await store.write(next);
  expect(await file.readAsString(), next.encode());
  final kept = Directory(p.join(support.path, 'recovery-quarantine'));
  final copies = [
    if (kept.existsSync())
      for (final entry in kept.listSync(recursive: true))
        if (entry is File) entry,
  ];
  if (books.lossy) {
    expect(copies, hasLength(1), reason: 'the old file is kept');
    expect(copies.single.readAsBytesSync(), utf8.encode(books.text));
  }
  if (_isCanonical(books)) {
    expect(copies, isEmpty, reason: 'nothing was lost, so nothing is kept');
  }
}

/// Whether [books] is exactly what BookList writes, a byte-order mark aside.
bool _isCanonical(_Books books) =>
    _json(books.text) == BookList.decode(_json(books.text)).encode();
