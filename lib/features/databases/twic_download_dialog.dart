import 'dart:async';

import 'package:flutter/material.dart';

import 'database_library.dart';
import '../../ui/theme.dart';
import '../../ui/number_field.dart';

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
      return PopScope(
        canPop: !download.running,
        child: AlertDialog(
          title: const Text('Download TWIC database'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Download recent weekly games from The Week in Chess. '
                  'Issues already in the database are skipped.',
                ),
                const SizedBox(height: Space.m),
                if (!download.running)
                  Row(
                    children: [
                      const Expanded(child: Text('Weeks')),
                      NumberField(
                        label: 'Weeks',
                        value: _weeks,
                        min: 1,
                        max: 520,
                        onChanged: (value) {
                          if (mounted) setState(() => _weeks = value);
                        },
                      ),
                    ],
                  ),
                if (download.running) ...[
                  LinearProgressIndicator(
                    value: download.total == 0
                        ? null
                        : download.done / download.total,
                  ),
                  const SizedBox(height: Space.m),
                ],
                if (waiting)
                  Text(
                    library.removing != null
                        ? 'Wait for the deletion to finish.'
                        : 'Wait for the import to finish.',
                  )
                else if (download.status.isNotEmpty)
                  Text(download.status),
                if (download.problem case final problem?)
                  Text(
                    problem,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (download.running)
              TextButton(onPressed: download.stop, child: const Text('Stop'))
            else ...[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              FilledButton(
                onPressed: waiting
                    ? null
                    : () {
                        FocusScope.of(context).unfocus();
                        FocusManager.instance.applyFocusChangesIfNeeded();
                        unawaited(library.downloadTwic(_weeks));
                      },
                child: Text(
                  download.problem == null ? 'Download' : 'Try again',
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
