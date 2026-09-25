import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/integrity_report.dart';
import 'integrity_check.dart';
import '../../ui/theme.dart';

Future<void> showIntegrityDialog(
  BuildContext context,
  IntegrityReader reader,
) => showDialog<void>(
  context: context,
  builder: (_) => IntegrityDialog(reader: reader),
);

class IntegrityDialog extends StatefulWidget {
  const IntegrityDialog({super.key, required this.reader});
  final IntegrityReader reader;
  @override
  State<IntegrityDialog> createState() => _IntegrityDialogState();
}

class _IntegrityDialogState extends State<IntegrityDialog> {
  late final _check = IntegrityCheck(widget.reader);
  @override
  void initState() {
    super.initState();
    unawaited(_check.refresh());
  }

  @override
  void dispose() {
    _check.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 680,
      height: 520,
      child: ListenableBuilder(
        listenable: _check,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Check saved data',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: Space.s),
              const Text(
                'Read-only report. Files are checked individually; saves during the check may affect findings.',
              ),
              const SizedBox(height: Space.m),
              if (_check.reading) const LinearProgressIndicator(),
              if (_check.problem case final problem?) Text(problem),
              Expanded(child: _report()),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _check.reading
                        ? null
                        : () => unawaited(_check.refresh()),
                    child: const Text('Check again'),
                  ),
                  const SizedBox(width: Space.s),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _report() {
    final report = _check.report;
    if (report == null)
      return Center(
        child: Text(
          _check.reading ? 'Checking saved data…' : 'No report is available.',
        ),
      );
    return ListView(
      children: [
        const SizedBox(height: Space.m),
        Text(
          report.clean
              ? 'No problems found in the checks completed.'
              : 'Findings: ${report.findings.length}; checks skipped: ${report.skipped.length}.',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text('Checked at ${report.checkedAt.toLocal()}'),
        for (final finding in report.findings)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(finding.detail),
                SelectableText(
                  finding.path,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        for (final skipped in report.skipped)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s),
            child: Text('Skipped: $skipped'),
          ),
        const SizedBox(height: Space.s),
        for (final checked in report.checked) Text('Checked: $checked'),
      ],
    );
  }
}
