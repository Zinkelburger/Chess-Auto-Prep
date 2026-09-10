/// The one "add to study" flow, shared by every producer (Player Analysis
/// lines, PGN viewer lines, solitaire games, tactics source games): study
/// picker → chapter write. Successful additions finish quietly; explicit
/// edit requests open Study mode on the new chapter.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/study_controller.dart';
import '../../services/storage/storage_factory.dart';
import '../../utils/app_messages.dart';
import '../pgn/add_to_study_dialog.dart';

/// Runs the complete flow. [buildPgn] receives the chapter name the user
/// settled on and returns the chapter PGN (null aborts silently — the
/// builder is expected to have surfaced its own error).
///
/// [openAfterAdding] is for explicit "Edit in study" requests. [viewSanLine]
/// optionally parks that editor on the position being discussed.
Future<void> runAddToStudyFlow(
  BuildContext context, {
  required String suggestedChapterName,
  required FutureOr<String?> Function(String chapterName) buildPgn,
  String pickerTitle = 'Add line to study',
  bool openAfterAdding = false,
  List<String>? viewSanLine,
  Future<String?> Function()? preferredStudy,
}) async {
  // Resolved before the picker so it can be listed first (an opponent's
  // prep file is created on first use, so this may write a file).
  final preferredPath = await preferredStudy?.call();
  if (!context.mounted) return;
  final result = await showDialog<AddToStudyResult>(
    context: context,
    builder: (_) => AddToStudyDialog(
      initialChapterName: suggestedChapterName,
      title: pickerTitle,
      preferredPath: preferredPath,
    ),
  );
  if (result == null || !context.mounted) return;

  final study = context.read<StudyController>();
  final appState = context.read<AppState>();
  try {
    final pgn = await buildPgn(result.chapterName);
    if (pgn == null || !context.mounted) return;
    final path =
        result.existingPath ??
        await StorageFactory.instance.studyFilePath(result.newStudyName!);
    await study.addChapterToStudyFile(path, result.chapterName, pgn);
    if (!context.mounted) return;
    if (openAfterAdding) {
      appState.handOff(
        EditStudy(
          studyPath: path,
          chapterName: result.chapterName,
          initialSanLine: viewSanLine,
        ),
        historyLabel: 'Study: ${result.studyName}',
      );
    }
  } catch (e) {
    debugPrint('Add to study failed: $e');
    if (context.mounted) {
      showAppSnackBar(context, 'Failed to add to study.', isError: true);
    }
  }
}
