/// Writing a selected model game as PGN, in both shapes the export needs.
///
/// A model game travels twice: inside the course as a chapter entry with
/// study headers (`[White]` = chapter, `[Black]` = variation, `[Result "*"]`,
/// the real game data under `ModelGame*` tags), and again in the companion
/// run-local `model_games.pgn` as a plain game record a PGN viewer opens as a
/// collection.  Both share one movetext, annotated at the move where the game
/// leaves the repertoire with what the repertoire does instead.
library;

import '../../../constants/chess_constants.dart';
import '../../../models/repertoire_line.dart'
    show
        kModelGameBlackEloTag,
        kModelGameBlackTag,
        kModelGameDateTag,
        kModelGameEventTag,
        kModelGameResultTag,
        kModelGameWhiteEloTag,
        kModelGameWhiteTag;
import '../../../utils/fen_utils.dart';
import '../export/move_annotation.dart';
import '../export/pgn_game_writer.dart';
import '../generation_config.dart';
import 'master_improvements.dart';
import 'model_game_selector.dart';
import 'opening_namer.dart' show formatMoveReference;

/// Renders [ModelGame]s as PGN text.
class ModelGameWriter {
  ModelGameWriter({required this.config, this.improvements = const {}})
    : startFen = config.startFen.isEmpty ? kStandardStartFen : config.startFen;

  final TreeBuildConfig config;

  /// Where the repertoire improves on master practice, keyed by the position
  /// the improvement is played in — cited in the departure note when the
  /// game's own move is the one improved on.
  final ImprovementMap improvements;

  /// Position the movetext starts from.  Retained games are scanned from the
  /// *build* root, so that is where they start — not the repertoire root the
  /// lines use.  Numbering follows it too, or a build started mid-game would
  /// renumber every model game.
  final String startFen;

  /// `Kasparov, G – Karpov, A, Linares 1993 (1-0)` — the game's name in the
  /// chapter's variation list.
  String label(ModelGame game) {
    final record = game.record;
    final occasion = [
      if (record.event.isNotEmpty && record.event != '?') record.event,
      if (record.year != null) '${record.year}',
    ].join(' ');
    final result = record.outcome?.pgnToken;
    return [
      record.playersLabel,
      if (occasion.isNotEmpty) ', $occasion',
      if (result != null) ' ($result)',
    ].join();
  }

  /// The game as a course chapter entry named [variationName] under
  /// [chapterName].
  ///
  /// A course chapter is study material, not a result-bearing game: `*` is
  /// what keeps header-based chapter detection working.  The real game data
  /// is preserved under unambiguous `ModelGame*` tags.
  String chapterPgn(
    ModelGame game, {
    required String courseTitle,
    required String chapterName,
    required String variationName,
  }) {
    final record = game.record;
    return _write(game, {
      'Event': courseTitle,
      'White': chapterName,
      'Black': variationName,
      'Result': '*',
      'Annotator': 'Chess Auto Prep',
      'Opening': variationName,
      kModelGameWhiteTag: record.white,
      kModelGameBlackTag: record.black,
      kModelGameResultTag: record.outcome?.pgnToken ?? '*',
      if (record.event.isNotEmpty) kModelGameEventTag: record.event,
      if (record.date.isNotEmpty) kModelGameDateTag: record.date,
      if (record.whiteElo > 0) kModelGameWhiteEloTag: '${record.whiteElo}',
      if (record.blackElo > 0) kModelGameBlackEloTag: '${record.blackElo}',
    }, result: '*');
  }

  /// The same game as a real game record for the companion file.
  String standalonePgn(ModelGame game, {required String courseTitle}) {
    final record = game.record;
    final result = record.outcome?.pgnToken ?? '*';
    return _write(game, {
      'Event': record.event.isEmpty ? '?' : record.event,
      'Site': '?',
      'Date': record.date.isEmpty ? '????.??.??' : record.date,
      'Round': '?',
      'White': record.white,
      'Black': record.black,
      'Result': result,
      if (record.whiteElo > 0) 'WhiteElo': '${record.whiteElo}',
      if (record.blackElo > 0) 'BlackElo': '${record.blackElo}',
      'Annotator': 'Chess Auto Prep',
      'Repertoire': courseTitle,
    }, result: result);
  }

  /// Movetext shared by both shapes: the game's moves from the build root,
  /// and at the move where it leaves the repertoire, what the repertoire does
  /// instead — a comment ("Our repertoire: 10...Qb6 — improves on 10...Nf6
  /// (+0.35)") and our mainline as a variation off that move, or, when the
  /// opponent left first, the replies we prepare.
  String _write(
    ModelGame game,
    Map<String, String> headers, {
    required String result,
  }) {
    final rootWhiteToMove = isWhiteToMove(startFen);
    final startMoveNumber = fullMoveNumber(startFen);
    // The movetext has to start where [startFen] does.  A build rooted
    // mid-opening writes its model games from that root, so the plies the
    // game spent reaching it are already on the board and must not be
    // written again — `1. d4` under a Benko FEN header is not a legal game.
    final movesSan = game.movesFromRoot;

    final annotations = <MoveAnnotation>[];
    final variations = <int, List<PgnSideline>>{};
    final departure = game.departure;
    if (departure != null && departure.index < movesSan.length) {
      final note = _departureNote(
        departure,
        rootWhiteToMove: rootWhiteToMove,
        startMoveNumber: startMoveNumber,
      );
      if (note != null) {
        annotations
          ..addAll(List.filled(departure.index, MoveAnnotation.none))
          ..add(MoveAnnotation(note: note));
      }
      if (departure.kind == DepartureKind.ours &&
          departure.repertoireLine.isNotEmpty) {
        variations[departure.index] = [PgnSideline(departure.repertoireLine)];
      }
    }

    return writePgnGame(
      PgnGameSpec(
        headers: headers,
        movesSan: movesSan,
        annotations: annotations,
        variations: variations,
        startFen: startFen,
        rootWhiteToMove: rootWhiteToMove,
        startMoveNumber: startMoveNumber,
        result: result,
      ),
      detail: config.annotationDetail,
    );
  }

  String? _departureNote(
    ModelGameDeparture departure, {
    required bool rootWhiteToMove,
    required int startMoveNumber,
  }) {
    String ref(String san) => formatMoveReference(
      san,
      departure.index,
      rootWhiteToMove: rootWhiteToMove,
      startMoveNumber: startMoveNumber,
    );
    switch (departure.kind) {
      case DepartureKind.ours:
        final ours = departure.repertoireSan;
        if (ours == null) return null;
        final improvement = improvements[departure.fenBefore];
        final improves =
            improvement != null &&
            improvement.ourSan == ours &&
            improvement.masterSan == departure.gameSan;
        final note = StringBuffer('Our repertoire: ${ref(ours)}');
        if (improves) {
          final pawns = (improvement.gainCp / 100).toStringAsFixed(2);
          note.write(' — improves on ${ref(departure.gameSan)} (+$pawns)');
        }
        return note.toString();
      case DepartureKind.opponent:
        if (departure.preparedReplies.isEmpty) return null;
        final prepared = departure.preparedReplies.map(ref).join(', ');
        return 'Outside the repertoire — prepared here: $prepared';
    }
  }
}
