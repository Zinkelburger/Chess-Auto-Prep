/// Shared per-chapter menu for the sidebar and compact chapter bar.
library;

import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';

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
List<PopupMenuEntry<ChapterAction>> studyChapterMenuItems(
  BuildContext context, {
  required bool canDelete,
}) => [
  PopupMenuItem(
    value: ChapterAction.edit,
    child: Text(AppLocalizations.of(context).studyEditChapterMenu),
  ),
  PopupMenuItem(
    value: ChapterAction.setStartingPosition,
    child: Text(AppLocalizations.of(context).studySetStartMenu),
  ),
  PopupMenuItem(
    value: ChapterAction.copyPgn,
    child: Text(AppLocalizations.of(context).studyCopyChapter),
  ),
  const PopupMenuDivider(),
  PopupMenuItem(
    value: ChapterAction.clearAnnotations,
    child: Text(AppLocalizations.of(context).studyClearAnnotationsMenu),
  ),
  PopupMenuItem(
    value: ChapterAction.clearVariations,
    child: Text(AppLocalizations.of(context).studyClearVariationsMenu),
  ),
  const PopupMenuDivider(),
  PopupMenuItem(
    value: ChapterAction.delete,
    enabled: canDelete,
    child: Text(AppLocalizations.of(context).studyDeleteChapterMenu),
  ),
];
