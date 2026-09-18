/// Shared per-chapter menu for the sidebar and compact chapter bar.
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

/// Menu entries in their fixed order.  [canDelete] is false for the last
/// chapter of a study, which keeps the entry visible but inert so the
/// menu does not change shape.
List<PopupMenuEntry<ChapterAction>> studyChapterMenuItems({
  required bool canDelete,
}) => [
  const PopupMenuItem(value: ChapterAction.edit, child: Text('Edit chapter…')),
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
