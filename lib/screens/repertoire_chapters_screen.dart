/// Chapter picker for a repertoire folder.
///
/// Pushed after the user taps a repertoire; pops the chosen chapter's
/// [RepertoireMetadata] (a `.pgn` file path) back to the caller.
library;

import 'package:flutter/material.dart';

import '../models/repertoire_metadata.dart';
import '../widgets/chapter_list_body.dart';

class RepertoireChaptersScreen extends StatelessWidget {
  final RepertoireMetadata repertoire;

  const RepertoireChaptersScreen({super.key, required this.repertoire});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(repertoire.name),
        actions: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      body: ChapterListBody(
        repertoire: repertoire,
        onSelected: (chapter) => Navigator.of(context).pop(chapter),
      ),
    );
  }
}
