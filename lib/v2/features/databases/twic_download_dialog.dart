import 'dart:async';

import 'package:flutter/material.dart';

import 'twic_download.dart';
import '../../ui/theme.dart';
import '../../ui/number_field.dart';

Future<void> showTwicDownload(BuildContext context, TwicDownload download) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TwicDialog(download: download),
    );

class _TwicDialog extends StatefulWidget {
  const _TwicDialog({required this.download});
  final TwicDownload download;

  @override
  State<_TwicDialog> createState() => _TwicDialogState();
}

class _TwicDialogState extends State<_TwicDialog> {
  int _weeks = 52;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.download,
    builder: (context, _) {
      final download = widget.download;
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
                  'Download recent weekly games from The Week in Chess for offline opening exploration.',
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
                if (download.status.isNotEmpty) Text(download.status),
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
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  FocusManager.instance.applyFocusChangesIfNeeded();
                  unawaited(download.start(_weeks));
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
