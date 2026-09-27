import 'package:flutter/material.dart';

import '../../storage/pgn_export.dart';
import '../../ui/name_dialog.dart';
import 'pgn_viewer.dart';

Future<void> exportViewerPgn(
  BuildContext context,
  PgnViewer viewer,
  void Function(String?) say,
) async {
  final text = viewer.exportText();
  if (text == null) {
    say('Wait for filtering to finish and select at least one game.');
    return;
  }
  final name = await showNameDialog(
    context,
    title: 'Export visible games',
    label: 'PGN file name',
    confirm: 'Choose folder',
    initial: '${viewer.file!.name} selection.pgn',
  );
  if (name == null) return;
  final result = await viewer.export(
    name.toLowerCase().endsWith('.pgn') ? name : '$name.pgn',
    text,
  );
  if (result case PgnExportFailed(:final message)) say(message);
}
