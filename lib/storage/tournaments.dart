import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:document_file_io/document_file_io.dart';

import '../chess/tournament/config.dart';
import '../chess/tournament/result.dart';
import '../chess/tournament/positions.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'document_ref.dart';
import 'edit_scope.dart';
import 'file_lock.dart';
import 'operation_journal.dart';
import 'pgn_document_store.dart';
import 'recovery_files.dart';
import 'recovery_quarantine.dart';
import 'tournament_inbox.dart';

sealed class TournamentResult<T> {
  const TournamentResult();
}

final class TournamentSaved<T> extends TournamentResult<T> {
  const TournamentSaved(this.value, {this.warnings = const []});
  final T value;
  final List<String> warnings;
}

final class TournamentFailed<T> extends TournamentResult<T> {
  const TournamentFailed(this.message);
  final String message;
}

abstract interface class TournamentPreviews {
  Future<TournamentResult<List<String?>>> positions(String id);
}

abstract interface class TournamentStore {
  Future<TournamentResult<List<Tournament>>> list();
  Future<TournamentResult<Tournament>> create(Tournament initial);
  Future<TournamentResult<Tournament>> save(
    Tournament before,
    Tournament after,
    String pgn, {
    required String? expectedPgn,
  });
  Future<TournamentResult<void>> remove(Tournament tournament);
  Future<TournamentResult<List<TournamentEngine>>> engines();
  Future<TournamentResult<void>> saveEngines(
    List<TournamentEngine> before,
    List<TournamentEngine> after,
  );
  DocumentRef games(String id);
}

/// PGN and metadata are one recoverable command. The private pending record
/// keeps both metadata states, the new PGN and the hash of the PGN it
/// replaces until the document store and JSON commit.
/// Replays accept an already-applied participant and refuse unrelated edits.
final class FileTournaments
    implements TournamentStore, TournamentNotifications, TournamentPreviews {
  FileTournaments({
    required Directory root,
    required this.support,
    required this.documents,
    this.afterPgn,
  }) : _configuredRoot = root,
       root = canonicalRecoveryRoot(root);
  final Directory _configuredRoot;
  final Directory root;
  final Directory support;
  final PgnDocumentStore documents;
  final Future<void> Function()? afterPgn;

  @override
  Future<TournamentResult<List<String?>>> positions(String id) =>
      _guard('read tournament positions', () async {
        final text = await _pgn(id);
        return text == null
            ? <String?>[]
            : Isolate.run(() => tournamentPositions(text));
      });

  @override
  Stream<void> changes() => TournamentInbox(root).changes();
  @override
  Future<String?> takeRequest() {
    _checkRoot();
    return TournamentInbox(root).takeRequest();
  }

  void _checkRoot() {
    if (canonicalRecoveryRoot(_configuredRoot).path != root.path)
      throw const FileSystemException('Tournament directory changed.');
  }

  String _folder(String id) {
    _checkRoot();
    if (id.isEmpty ||
        id.startsWith('.') ||
        p.basename(id) != id ||
        id.contains('\\') ||
        id.contains('\u0000'))
      throw const FormatException('Invalid tournament identity.');
    return p.join(root.path, id);
  }

  @override
  DocumentRef games(String id) => DocumentRef(p.join(_folder(id), 'games.pgn'));
  String _metadata(String id) => p.join(_folder(id), 'tournament.json');
  String _pending(String id) => p.join(_folder(id), '.v2-pending.json');

  @override
  Future<TournamentResult<List<Tournament>>> list() async {
    final warnings = <String>[];
    final result = await _guard('list tournaments', () async {
      _checkRoot();
      if (!await recoveryDirectory(root)) return <Tournament>[];
      return withDirectoryLock(root, () async {
        final found = <Tournament>[];
        await for (final entry in root.list(followLinks: false)) {
          if (entry is! Directory || p.basename(entry.path).startsWith('.'))
            continue;
          final id = p.basename(entry.path);
          final tournament = await _readTournament(id, warnings);
          if (tournament != null) found.add(tournament);
        }
        found.sort(
          (a, b) =>
              '${b.json['createdAt']}'.compareTo('${a.json['createdAt']}'),
        );
        return found;
      });
    });
    return switch (result) {
      TournamentSaved(:final value) => TournamentSaved(
        value,
        warnings: List.unmodifiable(warnings),
      ),
      TournamentFailed(:final message) => TournamentFailed(message),
    };
  }

  Future<Tournament?> _readTournament(String id, List<String> warnings) async {
    try {
      await _recover(id);
      final text = await recoveryText(_metadata(id));
      if (text == null) return null;
      final tournament = Tournament(tournamentObject(jsonDecode(text)));
      if (tournament.id != id)
        throw const FormatException('Mismatched tournament identity.');
      return tournament;
    } on Object catch (error) {
      log.w('read tournament $id', _reason(error));
      warnings.add('Cannot read tournament $id: ${_reason(error)}');
      return null;
    }
  }

  @override
  Future<TournamentResult<Tournament>> create(Tournament initial) => _guard(
    'create tournament',
    () async {
      if (initial.config.problem case final problem?) throw StateError(problem);
      await recoveryDirectory(root, create: true);
      return withDirectoryLock(root, () async {
        final folder = Directory(_folder(initial.id));
        await recoveryDirectory(folder, create: true);
        final current = await recoveryText(_metadata(initial.id));
        if (current != null && !_same(current, initial))
          throw StateError('That tournament already exists.');
        if (current == null)
          await _publish(_metadata(initial.id), _encoded(initial));
        return initial;
      });
    },
  );

  @override
  Future<TournamentResult<Tournament>> save(
    Tournament before,
    Tournament after,
    String pgn, {
    required String? expectedPgn,
  }) => _guard('save tournament ${before.id}', () async {
    if (before.id != after.id) throw StateError('Tournament identity changed.');
    return withDirectoryLock(root, () async {
      if (!await recoveryDirectory(Directory(_folder(before.id))))
        throw StateError('The tournament was removed.');
      await _recover(before.id);
      final current = await recoveryText(_metadata(before.id));
      final target = _encoded(after);
      final prior = await documents.open(games(before.id));
      final written = _text(prior);
      if (current == target && written == pgn) return after;
      if (!_same(current, before))
        throw StateError('The tournament changed in another window.');
      if (written != expectedPgn)
        throw StateError('The saved games changed in another window.');
      // Version 2 names the PGN it replaces by hash: a checkpoint journals
      // the new games once rather than the whole file twice.
      final record = <String, Object?>{
        'version': 2,
        'before': current,
        'after': target,
        'pgnBeforeSha256': written == null ? null : _sha256(written),
        'pgnAfter': pgn,
      };
      await _publish(_pending(before.id), jsonEncode(record));
      await _finish(before.id, record, prior);
      return after;
    });
  });

  Future<String?> _pgn(String id) async =>
      _text(await documents.open(games(id)));

  Future<void> _recover(String id) async {
    final record = File(_pending(id));
    final text = await recoveryText(record.path);
    if (text == null) return;
    final Map<String, Object?> data;
    try {
      data = tournamentObject(jsonDecode(text));
      // Version 1 records, which keep the whole earlier PGN, stay readable.
      final before = switch (data['version']) {
        1 => data['pgnBefore'],
        2 => data['pgnBeforeSha256'],
        _ => 0,
      };
      if ((before != null && before is! String) ||
          data['after'] is! String ||
          data['pgnAfter'] is! String)
        throw const FormatException('Invalid tournament recovery record.');
    } on FormatException catch (error) {
      await _setAside(record, _reason(error));
    }
    await _finish(id, data);
  }

  /// Carries [record] through the games, then the metadata. [prior] is the
  /// PGN as the caller just read and checked under the same lock; recovery
  /// reads it here. A save that cannot finish for now keeps its record for
  /// the next access; one another writer overtook is set aside.
  Future<void> _finish(
    String id,
    Map<String, Object?> record, [
    DocumentRead? prior,
  ]) async {
    final settlement = await finishParticipants((
      pivots: [
        _Games(documents, games(id), record, prior),
        _Metadata(_metadata(id), record, afterPgn),
      ],
      references: const [],
    ), describe: _reason);
    switch (settlement) {
      case Finished():
        await File(_pending(id)).delete();
        await flushRecoveryDirectory(_folder(id));
      case SetAside(:final detail):
        await _setAside(File(_pending(id)), detail);
      case Deferred(:final detail) || Refused(reason: Refusal(:final detail)):
        throw _Unfinished(detail);
    }
  }

  Future<Never> _setAside(File record, String detail) async {
    await quarantine(support, record, detail);
    throw StateError(
      'Tournament recovery found a conflict; its record was set aside for inspection.',
    );
  }

  @override
  Future<TournamentResult<void>> remove(Tournament tournament) =>
      _guard('remove tournament', () async {
        await withDirectoryLock(root, () async {
          await _recover(tournament.id);
          if (!_same(await recoveryText(_metadata(tournament.id)), tournament))
            throw StateError(
              'The tournament changed. Refresh before deleting it.',
            );
          final trash = Directory(p.join(root.path, '.trash'));
          await recoveryDirectory(trash, create: true);
          await movePathNoReplace(
            _folder(tournament.id),
            p.join(
              trash.path,
              '${tournament.id}-${DateTime.now().microsecondsSinceEpoch}',
            ),
          );
          await flushRecoveryDirectory(trash.path);
          await flushRecoveryDirectory(root.path);
        });
      });

  @override
  Future<TournamentResult<List<TournamentEngine>>> engines() => _guard(
    'read tournament engines',
    () async {
      _checkRoot();
      final text = await recoveryText(p.join(root.path, 'engines.json'));
      if (text == null) return <TournamentEngine>[];
      final data = jsonDecode(text);
      if (data is! List)
        throw const FormatException('Invalid engine registry.');
      return [for (final row in data) TournamentEngine(tournamentObject(row))];
    },
  );

  @override
  Future<TournamentResult<void>> saveEngines(
    List<TournamentEngine> before,
    List<TournamentEngine> after,
  ) => _guard('save tournament engines', () async {
    _checkRoot();
    await recoveryDirectory(root, create: true);
    await withDirectoryLock(root, () async {
      final path = p.join(root.path, 'engines.json');
      final current = await recoveryText(path);
      final expected = jsonEncode([for (final e in before) e.json]);
      final target = jsonEncode([for (final e in after) e.json]);
      if (current != null && jsonEncode(jsonDecode(current)) == target) return;
      if ((current == null && before.isNotEmpty) ||
          (current != null && jsonEncode(jsonDecode(current)) != expected))
        throw StateError('The engine registry changed. Refresh before saving.');
      await _publish(path, target);
    });
  });
}

String? _text(DocumentRead read) => switch (read) {
  Opened(:final text) => text,
  Absent() => null,
  _ => throw StateError('The tournament PGN could not be read.'),
};
String _sha256(String text) => sha256.convert(utf8.encode(text)).toString();

/// Whether [text] is [tournament] as written. The time label is the time
/// control in other words, so a file written before it was kept is the same
/// tournament.
bool _same(String? text, Tournament tournament) {
  if (text == null) return false;
  Map<String, Object?> content(Map<String, Object?> json) =>
      Map.of(json)..remove(_timeLabel);
  final read = jsonDecode(text);
  return read is Map<String, Object?> &&
      jsonEncode(content(read)) == jsonEncode(content(tournament.json));
}

/// The tournament as `tournament.json` holds it, with its time control in
/// words (`Blitz · 60 s + 0.6 s`) for the tools that list tournaments
/// without the app's code: the app is the one source of that label.
String _encoded(Tournament tournament) =>
    jsonEncode({...tournament.json, _timeLabel: tournament.config.timeLabel});
const _timeLabel = 'timeLabel';
String _reason(Object error) => error is FormatException
    ? 'Unreadable or conflicting tournament data.'
    : '$error';
Future<void> _publish(String path, String text) async {
  await discardLeftoverStage(path);
  if (await recoveryText(path) == null) {
    await createFileExclusively(path, utf8.encode(text));
  } else {
    await replaceFile(path, utf8.encode(text));
  }
}

/// A tournament's games, through the document store: before is the PGN the
/// record names (whole in version 1, by hash in version 2), after the new
/// one. Games once published stay as they are, even when the save is set
/// aside.
final class _Games implements Pivot {
  _Games(this.documents, this.ref, this.record, this._read);
  final PgnDocumentStore documents;
  final DocumentRef ref;
  final Map<String, Object?> record;

  /// The games as last read; a save passes the read it checked.
  DocumentRead? _read;

  String get _after => record['pgnAfter'] as String;

  @override
  Set<String> get paths => {ref.path};

  @override
  Future<Holds> look() async {
    final read = _read ??= await documents.open(ref);
    if (read is Unreadable) {
      return const CannotTell('The tournament PGN could not be read.');
    }
    final text = _text(read);
    if (text == _after) return const HoldsAfter();
    final before = record['version'] == 1
        ? text == record['pgnBefore']
        : (text == null ? null : _sha256(text)) == record['pgnBeforeSha256'];
    return before
        ? const HoldsBefore()
        : const HoldsOther('Tournament recovery found an external edit.');
  }

  @override
  Future<void> apply() async {
    final Object saved = switch (_read) {
      Opened(:final revision) => await documents.save(
        ref,
        _after,
        expected: revision,
        scope: const WholeDocument(),
      ),
      _ => await documents.create(ref, _after),
    };
    switch (saved) {
      case Saved() || Created():
        return;
      case Conflict() || Collision():
        throw const PivotTaken(
          'The tournament PGN changed while it was saved.',
        );
      default:
        throw StateError('The tournament PGN was not saved. Retry to finish.');
    }
  }

  /// The store's save is durable once it answers.
  @override
  Future<void> settle() async {}

  @override
  Future<bool> putBack() async => false;
}

/// `tournament.json`, exactly as the record has it before and after.
/// [afterPgn] runs before it is written, where a crash between the two
/// files lands.
final class _Metadata implements Pivot {
  _Metadata(this.path, this.record, this.afterPgn);
  final String path;
  final Map<String, Object?> record;
  final Future<void> Function()? afterPgn;

  @override
  Set<String> get paths => {path};

  @override
  Future<Holds> look() async {
    final String? text;
    try {
      text = await recoveryText(path);
    } on RecoveryRequired catch (error) {
      return CannotTell(error.detail);
    } on FileSystemException catch (error) {
      return CannotTell('$error');
    }
    if (text == record['after']) return const HoldsAfter();
    return text == record['before']
        ? const HoldsBefore()
        : const HoldsOther('Tournament recovery found an external edit.');
  }

  @override
  Future<void> apply() async {
    await afterPgn?.call();
    try {
      final text = await recoveryText(path);
      if (text == record['after']) return;
      if (text != record['before'])
        throw const PivotTaken('Tournament metadata changed during save.');
      await _publish(path, record['after'] as String);
    } on RecoveryRequired catch (error) {
      // Unreadable or linked for now, as look treats it: retry next access.
      throw _Unfinished(error.detail);
    }
  }

  /// The folder is flushed with the record's removal.
  @override
  Future<void> settle() async {}

  @override
  Future<bool> putBack() async {
    final before = record['before'];
    if (before is! String || await recoveryText(path) != record['after'])
      return false;
    await _publish(path, before);
    return true;
  }
}

/// A save that stopped for a passing reason; its record finishes on the
/// next access to the tournament.
final class _Unfinished implements Exception {
  const _Unfinished(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

Future<TournamentResult<T>> _guard<T>(
  String action,
  Future<T> Function() work,
) async {
  try {
    return TournamentSaved(await work());
  } on Object catch (error) {
    log.w(action, _reason(error));
    return TournamentFailed(_reason(error));
  }
}
