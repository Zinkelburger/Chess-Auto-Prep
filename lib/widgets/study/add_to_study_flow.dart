/// The one "add to study" flow, shared by every producer (Player Analysis
/// lines, PGN viewer lines, solitaire games, tactics source games): study
/// picker → chapter write → a confirmation dialog whose "View line" action
/// opens Study mode parked on the new chapter.
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
/// [viewSanLine], when given, parks the Study cursor at the deepest node
/// reachable by that SAN sequence — pass it for single-line adds so "View
/// line" lands on the position being discussed; leave it null for whole-game
/// adds, which read better from the start.
Future<void> runAddToStudyFlow(
  BuildContext context, {
  required String suggestedChapterName,
  required FutureOr<String?> Function(String chapterName) buildPgn,
  String pickerTitle = 'Add line to study',
  String viewActionLabel = 'View line',
  List<String>? viewSanLine,
}) async {
  final result = await showDialog<AddToStudyResult>(
    context: context,
    builder: (_) => AddToStudyDialog(
      initialChapterName: suggestedChapterName,
      title: pickerTitle,
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
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Added to study'),
        content: Text(
          'Chapter "${result.chapterName}" is now in '
          '"${result.studyName}".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              appState.handOff(
                EditStudy(
                  studyPath: path,
                  chapterName: result.chapterName,
                  initialSanLine: viewSanLine,
                ),
                historyLabel: 'Study: ${result.studyName}',
              );
            },
            child: Text(viewActionLabel),
          ),
        ],
      ),
    );
  } catch (e) {
    debugPrint('Add to study failed: $e');
    if (context.mounted) {
      showAppSnackBar(context, 'Failed to add to study.', isError: true);
    }
  }
}
