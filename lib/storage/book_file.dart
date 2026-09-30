import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'book_list.dart';
import 'book_references.dart';
import 'book_snapshot.dart';
import 'document_probe.dart';
import 'document_ref.dart';
import 'file_lock.dart';
import 'recovery_files.dart';
import 'recovery_gate.dart';
import 'recovery_quarantine.dart';

/// Where the books are kept. The filesystem is a real boundary, so this is
/// an interface: [BookFile] in the app, [MemoryBooks] in a test.
abstract interface class BookStore {
  /// The books as last written; [BookList.empty] when there is no file yet.
  /// Throws when there is one and it cannot be read.
  Future<BookList> read();

  /// Membership and its native source are one observation.
  Future<BookSnapshot> snapshot();

  /// Returns the installed snapshot only after publication is acknowledged.
  Future<BookSnapshot> write(BookList books);
}

/// [BookFile.write] refused because `books.json` changed since it was last
/// read. A fresh [BookStore.snapshot] is the baseline the next write needs.
final class BookConflict implements Exception {
  const BookConflict();

  @override
  String toString() => 'Books changed in another instance.';
}

/// The native publication boundary, including its staged-file receipt.
typedef BookPublish =
    Future<void> Function(
      String path,
      List<int> bytes, {
      void Function(NativeFileObservation)? installed,
    });

/// `books.json` in the app's support folder, written whole and atomically.
final class BookFile implements BookStore {
  BookFile(
    Directory support, {
    required this._recovery,
    this._publish = replaceFile,
  }) : _configuredSupport = Directory(p.normalize(p.absolute(support.path))),
       _support = canonicalRecoveryRoot(support);

  final RecoveryGate _recovery;
  final Directory _configuredSupport;
  final Directory _support;
  final BookPublish _publish;
  String get _path => p.join(_support.path, 'books.json');

  /// Exact optimistic read set, including unknown JSON fields. The document
  /// adapter captures this before waiting for its compound commit locks.
  Future<String?> expectedText() async {
    if (!_read) await snapshot();
    return _baseline;
  }

  String? _baseline;
  String? _attempted;
  bool _read = false;
  int _revision = 0;

  @override
  Future<BookList> read() async => (await snapshot()).value;

  @override
  Future<BookSnapshot> snapshot() async {
    final revision = ++_revision;
    _checkRoots();
    final observed = await _recovery.run(
      () => withDirectoryLock(_support, _observe),
    );
    final text = observed.text;
    final value = text == null ? BookList.empty : BookList.decode(_json(text));
    // A late read must not rebase an already admitted writer onto another
    // process's change. The returned value/proof remain paired regardless.
    if (revision == _revision) {
      _baseline = text;
      _attempted = null;
      _read = true;
    }
    return BookSnapshot(value: value, source: observed.source);
  }

  @override
  Future<BookSnapshot> write(BookList books) async {
    _revision++;
    final value = immutableBooks(books);
    final next = value.encode();
    final baseline = _baseline;
    final attempted = _attempted;
    final read = _read;
    _checkRoots();
    return _recovery.run(() async {
      _checkRoots();
      await _support.create(recursive: true);
      return withDirectoryLock(_support, () async {
        final current = (await _observe()).text;
        final knownAfter =
            current == next || (attempted != null && current == attempted);
        if (!knownAfter &&
            ((!read && current != null) || (read && current != baseline))) {
          throw const BookConflict();
        }
        if (current != null && current != next && !_roundTrips(current)) {
          // What this build cannot read would be gone after the write.
          await quarantineCopy(
            _support,
            'books.json',
            utf8.encode(current),
            'books.json holds what this build cannot read',
          );
        }
        await discardLeftoverStage(_path);
        // Keep both possible outcomes until publication is acknowledged. A
        // successor can follow verified prior bytes; an unrelated edit conflicts.
        _baseline = current;
        _read = true;
        _attempted = next;
        Revision? installed;
        await _publish(
          _path,
          utf8.encode(next),
          installed: (file) => installed = _installedRevision(file),
        );
        if (installed == null) {
          throw StateError('The book publication has no native receipt.');
        }
        _baseline = next;
        _attempted = null;
        _revision++;
        return BookSnapshot(value: value, source: _source(installed));
      });
    });
  }

  void _checkRoots() {
    if (canonicalRecoveryRoot(_configuredSupport).path != _support.path ||
        canonicalRecoveryRoot(_recovery.support).path != _support.path) {
      throw StateError('The configured book profile root changed.');
    }
  }

  BookSource _source(Revision? revision) => BookSource(
    supportPath: _configuredSupport.path,
    canonicalSupport: _support.path,
    revision: revision,
  );

  Future<({String? text, BookSource source})> _observe() async {
    _checkRoots();
    final file = await probeDocument(_path);
    _checkRoots();
    return switch (file) {
      FileMissing() => (text: null, source: _source(null)),
      FileUnreadable(:final detail) => throw FileSystemException(detail, _path),
      FileFound(:final bytes, :final revision) => (
        // UTF-8 decoding strips a BOM. Keep it in the optimistic raw baseline.
        text: exactText(bytes),
        source: _source(revision),
      ),
    };
  }
}

/// [text] without the byte-order mark UTF-8 decoding would have dropped.
String _json(String text) =>
    text.startsWith('\ufeff') ? text.substring(1) : text;

/// Whether writing back what [BookList.decode] reads from [text] keeps all
/// of it: every book, every field and a version this build knows.
bool _roundTrips(String text) {
  try {
    final json = _json(text);
    readBookDocument(json);
    return const DeepCollectionEquality.unordered().equals(
      jsonDecode(json),
      jsonDecode(BookList.decode(json).encode()),
    );
  } on FormatException {
    return false;
  }
}

Revision _installedRevision(NativeFileObservation file) {
  final hash = file.sha256Hex;
  final identity = file.identity;
  if (file.status != 0 || hash == null || identity == null) {
    throw StateError('The installed book file could not be identified.');
  }
  return Revision(hash, nativeIdentity: identity);
}

/// Books kept in memory, for a test.
final class MemoryBooks implements BookStore {
  MemoryBooks([this.books = BookList.empty]);

  BookList books;

  @override
  Future<BookList> read() async => (await snapshot()).value;

  @override
  Future<BookSnapshot> snapshot() async => BookSnapshot(value: books);

  @override
  Future<BookSnapshot> write(BookList books) async {
    final snapshot = BookSnapshot(value: books);
    this.books = snapshot.value;
    return snapshot;
  }
}
