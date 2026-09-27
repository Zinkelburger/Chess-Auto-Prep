import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
/// keeps both before/after states until the document store and JSON commit.
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
          try {
            await _recover(id);
            final text = await recoveryText(_metadata(id));
            if (text == null) continue;
            final tournament = Tournament(tournamentObject(jsonDecode(text)));
            if (tournament.id != id)
              throw const FormatException('Mismatched tournament identity.');
            found.add(tournament);
          } on Object catch (error) {
            log.w('read tournament $id', _reason(error));
            warnings.add('Cannot read tournament $id: ${_reason(error)}');
          }
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
      if (current == target && await _pgn(before.id) == pgn) return after;
      if (!_same(current, before))
        throw StateError('The tournament changed in another window.');
      if (await _pgn(before.id) != expectedPgn)
        throw StateError('The saved games changed in another window.');
      final journal = jsonEncode({
        'version': 1,
        'before': current,
        'after': target,
        'pgnBefore': await _pgn(before.id),
        'pgnAfter': pgn,
      });
      await _publish(_pending(before.id), journal);
      await _apply(before.id, tournamentObject(jsonDecode(journal)));
      return after;
    });
  });

  Future<String?> _pgn(String id) async {
    final result = await documents.open(games(id));
    return switch (result) {
      Opened(:final text) => text,
      Absent() => null,
      _ => throw StateError('The tournament PGN could not be read.'),
    };
  }

  Future<void> _recover(String id) async {
    final record = File(_pending(id));
    final text = await recoveryText(record.path);
    if (text == null) return;
    try {
      final data = tournamentObject(jsonDecode(text));
      if (data['version'] != 1 ||
          data['after'] is! String ||
          data['pgnAfter'] is! String)
        throw const FormatException('Invalid tournament recovery record.');
      await _apply(id, data);
    } on FormatException catch (error) {
      await quarantine(support, record, _reason(error));
      throw StateError(
        'Tournament recovery found a conflict; its record was set aside for inspection.',
      );
    }
  }

  Future<void> _apply(String id, Map<String, Object?> record) async {
    final metadata = await recoveryText(_metadata(id));
    final prior = await documents.open(games(id));
    final current = switch (prior) {
      Opened(:final text) => text,
      Absent() => null,
      _ => throw StateError('The tournament PGN could not be read.'),
    };
    final target = record['pgnAfter'] as String;
    if ((metadata != record['before'] && metadata != record['after']) ||
        (current != record['pgnBefore'] && current != target))
      throw const FormatException(
        'Tournament recovery found an external edit.',
      );
    if (current != target) {
      final Object saved = prior is Opened
          ? await documents.save(
              games(id),
              target,
              expected: prior.revision,
              scope: const WholeDocument(),
            )
          : await documents.create(games(id), target);
      if (saved is! Created && saved is! Saved)
        throw StateError('The tournament PGN was not saved. Retry to finish.');
    }
    await afterPgn?.call();
    final checked = await recoveryText(_metadata(id));
    if (checked != metadata && checked != record['after'])
      throw const FormatException('Tournament metadata changed during save.');
    if (checked != record['after'])
      await _publish(_metadata(id), record['after'] as String);
    await File(_pending(id)).delete();
    await flushRecoveryDirectory(_folder(id));
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

bool _same(String? text, Tournament tournament) =>
    text != null && jsonEncode(jsonDecode(text)) == _encoded(tournament);
String _encoded(Tournament tournament) => jsonEncode(tournament.json);
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
