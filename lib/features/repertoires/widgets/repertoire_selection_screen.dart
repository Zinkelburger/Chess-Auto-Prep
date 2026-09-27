/// Repertoire selection screen
/// Workspace destination that wraps [RepertoireListBody] with a destination heading.
/// Pops a [ChapterPick]: the chosen chapter file, plus the course chapter
/// inside it when the user tapped one.
library;

import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';

import '../../../widgets/chapter_list_body.dart' show ChapterPick;
import 'repertoire_list_body.dart';

class RepertoireSelectionScreen extends StatelessWidget {
  const RepertoireSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(AppLocalizations.of(context).selectRepertoire),
        actions: [
          IconButton(
            tooltip: AppLocalizations.of(context).back,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      body: RepertoireListBody(
        onRepertoireSelected: (folder) =>
            Navigator.of(context).pop(ChapterPick(folder)),
        onSelected: (chapter) =>
            Navigator.of(context).pop(ChapterPick(chapter)),
        onCourseChapterSelected: (chapter, courseChapter) => Navigator.of(
          context,
        ).pop(ChapterPick(chapter, courseChapter: courseChapter)),
      ),
    );
  }
}
