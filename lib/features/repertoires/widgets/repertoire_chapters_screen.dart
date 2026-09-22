/// Chapter picker for a repertoire folder.
///
/// Pushed after the user taps a repertoire; pops the chosen [ChapterPick] —
/// a chapter file, and the course chapter inside it when one was tapped —
/// back to the caller.
library;

import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';

import '../models/repertoire_metadata.dart';
import '../../../widgets/chapter_list_body.dart';
import '../../../design_system/components/item_title.dart';

class RepertoireChaptersScreen extends StatelessWidget {
  final RepertoireMetadata repertoire;

  const RepertoireChaptersScreen({super.key, required this.repertoire});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: ItemTitle(repertoire.name, maxLines: 1),
        actions: [
          IconButton(
            tooltip: AppLocalizations.of(context).back,
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
