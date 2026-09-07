/// Repertoire selection screen
/// Full-screen push that wraps [RepertoireListBody] with its own Scaffold.
/// Pops a [ChapterPick]: the chosen chapter file, plus the course chapter
/// inside it when the user tapped one.
library;

import 'package:flutter/material.dart';

import '../widgets/chapter_list_body.dart' show ChapterPick;
import '../widgets/repertoire_list_body.dart';

class RepertoireSelectionScreen extends StatelessWidget {
  const RepertoireSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Select Repertoire'),
        actions: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      body: RepertoireListBody(
        onSelected: (chapter) =>
            Navigator.of(context).pop(ChapterPick(chapter)),
        onCourseChapterSelected: (chapter, courseChapter) => Navigator.of(
          context,
        ).pop(ChapterPick(chapter, courseChapter: courseChapter)),
      ),
    );
  }
}
