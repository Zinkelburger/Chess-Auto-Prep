import 'package:dartchess/dartchess.dart' show Side;

import '../chess/pgn/branch_edits.dart' as edits;
import '../chess/pgn/line_edits.dart' as edits;
import '../chess/pgn/game_tree.dart';
import 'document_session.dart';

/// The edits that move, remove or rewrite whole games of the open chapter.
///
/// Commands rather than methods on [DocumentSession]: each is one pure edit
/// from `chess/pgn/line_edits.dart` and `branch_edits.dart` handed to [DocumentSession.apply],
/// and a method that only passes a call on is a layer the session does not
/// need. A study's chapter operations are the same shape, in
/// `features/study/study_commands.dart`.

/// Renames the line at [game] — its `[Event]` tag, and nothing else.
void renameLine(DocumentSession session, int game, String name) =>
    session.apply((c) => edits.renamedLine(c, game: game, name: name));

/// Takes the line at [game] out of the file. Undo puts it back.
void deleteLine(DocumentSession session, int game) =>
    session.apply((c) => edits.lineDeleted(c, game: game));

/// Plays the chapter from [side]: the `// Color:` line, and the board.
void setSide(DocumentSession session, Side side) =>
    session.apply((c) => edits.sideSet(c, side));

/// Takes the move at [at] out of the chapter, and everything under it.
void deleteFrom(DocumentSession session, NodePath at) =>
    session.apply((c) => edits.movesDeleted(c, at: at));

/// Makes the move at [at] the first of the moves that share its parent.
void promoteVariation(DocumentSession session, NodePath at) =>
    session.apply((c) => edits.variationPromoted(c, at: at));

/// Makes the move at [at] part of the main line from the first move on.
void makeMainLine(DocumentSession session, NodePath at) =>
    session.apply((c) => edits.madeMainLine(c, at: at));
