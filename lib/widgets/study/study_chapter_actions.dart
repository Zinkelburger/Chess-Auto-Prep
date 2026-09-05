/// The per-chapter menu, built once and shown from every surface that has a
/// chapter row: the sidebar's gear, the compact chapter bar's overflow, the
/// chapter manager.  One list, so the surfaces cannot drift apart.
library;

import 'package:flutter/material.dart';

enum ChapterAction {
  edit,
  setStartingPosition,
  copyPgn,
  clearAnnotations,
  clearVariations,
  delete,
}

class StudyChapterActions {
  const StudyChapterActions({
    required this.onEdit,
    required this.onSetStartingPosition,
    required this.onCopyPgn,
    required this.onClearAnnotations,
    required this.onClearVariations,
    required this.onDelete,
  });

  final ValueChanged<int> onEdit;
  final ValueChanged<int> onSetStartingPosition;
  final ValueChanged<int> onCopyPgn;
  final ValueChanged<int> onClearAnnotations;
  final ValueChanged<int> onClearVariations;
  final ValueChanged<int> onDelete;

  /// Menu entries in their fixed order.  [canDelete] is false for the last
  /// chapter of a study, which keeps the entry visible but inert so the
  /// menu does not change shape.
  static List<PopupMenuEntry<ChapterAction>> menuItems({
    required bool canDelete,
  }) => [
    const PopupMenuItem(
      value: ChapterAction.edit,
      child: Text('Edit chapter…'),
    ),
    const PopupMenuItem(
      value: ChapterAction.setStartingPosition,
      child: Text('Set starting position…'),
    ),
    const PopupMenuItem(
      value: ChapterAction.copyPgn,
      child: Text('Copy chapter PGN'),
    ),
    const PopupMenuDivider(),
    const PopupMenuItem(
      value: ChapterAction.clearAnnotations,
      child: Text('Clear comments, glyphs and shapes…'),
    ),
    const PopupMenuItem(
      value: ChapterAction.clearVariations,
      child: Text('Clear variations…'),
    ),
    const PopupMenuDivider(),
    PopupMenuItem(
      value: ChapterAction.delete,
      enabled: canDelete,
      child: const Text('Delete chapter…'),
    ),
  ];

  void run(ChapterAction action, int index) {
    switch (action) {
      case ChapterAction.edit:
        onEdit(index);
      case ChapterAction.setStartingPosition:
        onSetStartingPosition(index);
      case ChapterAction.copyPgn:
        onCopyPgn(index);
      case ChapterAction.clearAnnotations:
        onClearAnnotations(index);
      case ChapterAction.clearVariations:
        onClearVariations(index);
      case ChapterAction.delete:
        onDelete(index);
    }
  }
}
