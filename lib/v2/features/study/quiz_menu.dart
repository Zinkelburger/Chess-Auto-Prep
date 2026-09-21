import 'package:flutter/material.dart';

import '../../chess/pgn/comment_text.dart';
import '../../chess/pgn/game_tree.dart';
import '../../chess/pgn/study.dart';
import '../../workspace/document_session.dart';

/// What a right-click on a move offers in a study: where training starts
/// asking, and where it stops.
///
/// A marker is a token in the move's comment, so it travels with the chapter
/// through an export, an import and anyone else's reader. The words on the
/// move are not touched, and each entry reads as what pressing it does.
List<Widget> quizMenuItems(DocumentSession session, NodePath path) {
  final comment = session.tree?.nodeAt(path)?.comment;
  if (comment == null && path.isRoot) return const [];
  final starts = hasToken(comment, quizStartMarker);
  final ends = hasToken(comment, quizEndMarker);
  return [
    _item(
      starts ? 'Do not start a quiz here' : 'Start quiz from this move',
      () => session.setMarker(path, quizStartMarker, on: !starts),
    ),
    _item(
      ends ? 'Do not end a quiz here' : 'End quiz after this move',
      () => session.setMarker(path, quizEndMarker, on: !ends),
    ),
  ];
}

MenuItemButton _item(String label, VoidCallback run) =>
    MenuItemButton(onPressed: run, child: Text(label));
