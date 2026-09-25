import 'dart:convert';

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/tactics/analyzed_games.dart';
import '../../chess/tactics/mined_set.dart';
import '../../chess/tactics/mining.dart';
import '../../chess/tactics/puzzle.dart';
import '../../diagnostics/log.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pgn_document_store.dart';
import '../../storage/pending_writes.dart';
import '../../workspace/document_saver.dart' show DocumentSaver;
import '../../workspace/document_session.dart';
import 'tactics_set.dart';

/// What adding a reviewed game's puzzles came to.
sealed class Addition {
  const Addition();
}

/// The puzzles are on disk and the game is marked done. [added] leaves out
/// puzzles whose position the set already had.
final class Added extends Addition {
  const Added(this.added);

  final int added;
}

/// Publication was not confirmed; [reason] explains the retained retry.
final class NotAdded extends Addition {
  const NotAdded(this.reason);

  final String reason;
}

/// Adds mined puzzles to the tactics set, and says which games are done.
///
/// The set has one writer at a time. While it is the document in the
/// workspace — a puzzle is up — the session is that writer: the puzzles go
/// in through [DocumentSession.apply] and out through its saver, which the
/// addition waits for, so an attempt the solver is recording and the new
/// puzzles are one queue of saves and neither overwrites the other. While
/// it is not open, this writes it through the store against the revision it
/// read, reading again when the file changed before publication.
///
/// Accepted writes hold the session's document-access barrier through their
/// publication, so a concurrent open waits for the resulting file.
final class SetAdditions {
  SetAdditions({
    required PgnDocumentStore documents,
    required DocumentSession session,
    required DocumentSaver saver,
    required TacticsSet set,
    required Future<Set<String>?> Function() older,
    PendingWrites? pendingWrites,
  }) : pendingWrites = pendingWrites ?? PendingWrites(),
       _documents = documents,
       _session = session,
       _saver = saver,
       _set = set,
       _older = older;

  final PendingWrites pendingWrites;
  final _commands = <String, _MinedCheckpoint>{};
  final PgnDocumentStore _documents;
  final DocumentSession _session;
  final DocumentSaver _saver;
  final TacticsSet _set;

  /// The ids the old app kept apart from the set, still counted as done;
  /// null when its file is there and could not be read.
  final Future<Set<String>?> Function() _older;

  /// How many times a write that lost a race with another writer is tried.
  static const _attempts = 3;

  /// The games already reviewed, by either app; null when the set or the
  /// old app's list cannot be read, which is no answer: mining then would
  /// mine again what was mined before.
  Future<Set<String>?> analyzed() async {
    final older = await _older();
    if (older == null) return null;
    return switch (await _documents.open(_set.ref)) {
      Absent() => older,
      Opened(:final text) => _idsIn(
        (await readChapter(name: _set.ref.name, text: text)).preamble,
        older,
      ),
      Unreadable(:final detail) => _unreadable(detail),
    };
  }

  /// An accepted checkpoint is retained until its caller consumes its receipt.
  /// This includes a registry retry that finished after its view went away.
  bool retained(String gameId) => _commands.containsKey(gameId);

  Future<Addition?> retry(String gameId) async =>
      await _commands[gameId]?.write.run();

  void acknowledge(String gameId) {
    if (_commands[gameId]?.write.committed ?? false) _commands.remove(gameId);
  }

  /// Freezes this game's puzzles before awaiting any read. The obligation and
  /// its count outlive the reviewing owner; retry performs no engine work.
  Future<Addition> add(String gameId, List<MinedPuzzle> puzzles) {
    final command = _commands.putIfAbsent(gameId, () {
      final accepted = _MinedCheckpoint(gameId, puzzles);
      accepted.write = pendingWrites.accept<Addition>(
        resource: this,
        label: 'Mined tactics set',
        work: () => _perform(accepted),
        problem: (result) => result is NotAdded ? result.reason : null,
        blocked: () => const NotAdded('An earlier game is not saved.'),
      );
      return accepted;
    });
    return command.write.run();
  }

  Future<Addition> _perform(_MinedCheckpoint command) async {
    try {
      return await _session.access.changing(_set.ref.path, () => _add(command));
    } on Object catch (error) {
      return NotAdded('$error');
    }
  }

  Future<Addition> _add(_MinedCheckpoint command) async {
    final older = await _older() ?? const <String>{};
    if (_set.isOpen) return _addInSession(command, older);
    for (var attempt = 1; attempt <= _attempts; attempt++) {
      final written = await _addOnDisk(command, older);
      if (written != null) {
        if (written is Added) await _set.load();
        return written;
      }
    }
    return const NotAdded('the set kept changing while it was written');
  }

  Future<Addition> _addInSession(
    _MinedCheckpoint command,
    Set<String> older,
  ) async {
    if (command.applied &&
        !(_idsIn(_session.chapter!.preamble, const {})?.contains(command.id) ??
            false)) {
      command.applied = false;
    }
    if (!command.applied) {
      final refused = _session.apply((set) {
        final edit = _edit(set, command.id, command.puzzles, older);
        if (edit is ChapterEdited) {
          command.remember(set, edit.chapter);
        }
        return edit;
      });
      if (refused != null) return NotAdded(refused);
      command.applied = true;
    }
    await _saver.flush();
    // A marker in a failed draft is not a completed checkpoint. In particular,
    // an unknown save acknowledgement must not discard unrelated editor words.
    if (!_saver.settled) return const NotAdded('the set could not be saved');
    final read = await _documents.open(_set.ref);
    if (read is! Opened)
      return const NotAdded('the mined game could not be read');
    final persisted = await readChapter(name: _set.ref.name, text: read.text);
    if (!(_idsIn(persisted.preamble, const {})?.contains(command.id) ??
            false) ||
        !command.matches(persisted)) {
      return const NotAdded(
        'the mined puzzles were changed or removed before their checkpoint was confirmed',
      );
    }
    return Added(command.added ?? 0);
  }

  /// One attempt; null when the file changed before publication. Navigation
  /// cannot adopt an old read while this command owns the access barrier.
  Future<Addition?> _addOnDisk(
    _MinedCheckpoint command,
    Set<String> older,
  ) async {
    final ref = _set.ref;
    switch (await _documents.open(ref)) {
      case Absent():
        final set = parseChapter(name: ref.name, text: '');
        final edit = _edit(set, command.id, command.puzzles, older);
        if (edit is! ChapterEdited) return _notEdited(edit);
        command.remember(set, edit.chapter);
        return switch (await _documents.create(ref, command.text!)) {
          Created() => Added(command.added!),
          Collision() => null,
          IoFailure(:final detail) => NotAdded(detail),
        };
      case Opened(:final readOnly?):
        return NotAdded(readOnly);
      case Opened(:final text, :final revision):
        if (text == command.text && command.added != null) {
          return Added(command.added!);
        }
        final set = await readChapter(name: ref.name, text: text);
        if (_set.isOpen) return _addInSession(command, older);
        final done = _idsIn(set.preamble, const {});
        if (done == null)
          return const NotAdded('the analyzed-games line is unreadable');
        if (done.contains(command.id)) {
          return command.text == null
              ? const Added(0)
              : const NotAdded(
                  'the set changed after an unconfirmed checkpoint',
                );
        }
        final edit = _edit(set, command.id, command.puzzles, older);
        if (edit is! ChapterEdited) return _notEdited(edit);
        command.remember(set, edit.chapter);
        return switch (await _documents.save(
          ref,
          command.text!,
          expected: revision,
          scope: GamesRearranged(edit.games),
        )) {
          Saved() => Added(command.added!),
          Conflict() => null,
          SaveDidNotLand(:final detail) => NotAdded(detail),
        };
      case Unreadable(:final detail):
        return NotAdded(detail);
    }
  }

  static ChapterEdit _edit(
    Chapter set,
    String gameId,
    List<MinedPuzzle> puzzles,
    Set<String> older,
  ) {
    final Set<String> done;
    try {
      done = {
        ...analyzedIn(set.preamble),
        ...older,
        if (gameId.isNotEmpty) gameId,
      };
    } on FormatException catch (error) {
      return ChapterEditRefused('its analysed-games line: ${error.message}');
    }
    return withMined(set, puzzles, analyzed: done);
  }

  static Addition _notEdited(ChapterEdit edit) => switch (edit) {
    ChapterEditRefused(:final reason) => NotAdded(reason),
    _ => const Added(0),
  };

  static Set<String>? _idsIn(String preamble, Set<String> older) {
    try {
      return {...analyzedIn(preamble), ...older};
    } on FormatException catch (error) {
      return _unreadable(error.message);
    }
  }

  static Set<String>? _unreadable(String detail) {
    log.w('read the analysed games of the tactics set', detail);
    return null;
  }
}

/// Frozen input and the one publication receipt still owed to the caller.
final class _MinedCheckpoint {
  _MinedCheckpoint(this.id, List<MinedPuzzle> puzzles)
    : puzzles = List.unmodifiable([
        for (final puzzle in puzzles)
          MinedPuzzle(
            fen: puzzle.fen,
            played: puzzle.played,
            kind: puzzle.kind,
            answer: List.unmodifiable(puzzle.answer),
            engineLine: List.unmodifiable(puzzle.engineLine),
            note: puzzle.note,
            refutation: puzzle.refutation,
            game: puzzle.game,
          ),
      ]);

  final String id;
  final List<MinedPuzzle> puzzles;
  late final PendingObligation<Addition> write;
  String? text;
  int? added;
  bool applied = false;
  List<String> _appended = const [];

  void remember(Chapter before, Chapter after) {
    text = writeChapter(after);
    added = after.lines.length - before.lines.length;
    _appended = [
      for (final line in after.lines.skip(before.lines.length)) _proof(line),
    ];
  }

  bool matches(Chapter persisted) {
    final present = [for (final line in persisted.lines) _proof(line)];
    return _appended.every(present.remove);
  }

  /// Puzzle identity includes its source and solution, while review headers,
  /// comments and unrelated display metadata can change independently.
  static String _proof(ChapterLine line) => jsonEncode([
    for (final key in [
      'GameId',
      'FEN',
      'UserMove',
      'MistakeType',
      'OpponentBestResponse',
      'SolutionPv',
      'SourceMovetext',
    ])
      tagValue(line.tags, key),
    puzzleOf(line, 0)?.answer,
  ]);
}
