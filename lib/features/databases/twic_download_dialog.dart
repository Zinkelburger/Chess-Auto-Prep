import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/field_row.dart';
import '../../ui/form_dialog.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import 'database_library.dart';

/// Downloads through [library], which keeps it from running beside an
/// import. Shown only where the library offers a download.
Future<void> showTwicDownload(BuildContext context, DatabaseLibrary library) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TwicDialog(library: library),
    );

class _TwicDialog extends StatefulWidget {
  const _TwicDialog({required this.library});
  final DatabaseLibrary library;

  @override
  State<_TwicDialog> createState() => _TwicDialogState();
}

class _TwicDialogState extends State<_TwicDialog> {
  int _weeks = 52;

  /// This dialog started a run, so its outcome is the dialog's own.
  bool _started = false;
  late final _changes = Listenable.merge([
    widget.library,
    widget.library.download,
  ]);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _changes,
    builder: (context, _) {
      final library = widget.library;
      final download = library.download!;
      final waiting = library.busy && !download.running;
      // A run this dialog started went through: nothing is left to do here,
      // so the only button closes it.
      final finished = _started && !download.running && download.finished;
      return FormDialog(
        title: 'Download TWIC',
        width: dialogMedium,
        busy: download.running,
        progress: download.total == 0 ? null : download.done / download.total,
        // While it runs the left button stops it rather than closing.
        cancel: finished
            ? null
            : download.running
            ? 'Stop'
            : 'Cancel',
        onCancel: download.running ? download.stop : null,
        confirm: finished ? 'Close' : 'Download',
        onConfirm: finished
            ? () => Navigator.of(context).pop()
            : waiting
            ? null
            : _download,
        canFail: true,
        problem: download.problem,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Download recent weekly games from The Week in Chess. '
              'Issues already in the database are skipped.',
            ),
            const SizedBox(height: Space.m),
            if (!download.running && !finished)
              FieldRow(
                label: 'Weeks',
                child: NumberField(
                  label: 'Weeks',
                  value: _weeks,
                  min: 1,
                  max: 520,
                  onChanged: (value) => setState(() => _weeks = value),
                ),
              ),
            if (waiting)
              Text(
                library.removing != null
                    ? 'Wait for the deletion to finish.'
                    : 'Wait for the import to finish.',
              )
            else if (download.status.isNotEmpty)
              Text(download.status),
          ],
        ),
      );
    },
  );

  /// Starts the download, which waits for another job on the databases to
  /// end; a number still being typed is taken first.
  void _download() {
    setState(() => _started = true);
    FocusScope.of(context).unfocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    unawaited(widget.library.downloadTwic(_weeks));
  }
}
