import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Read-only native observation; acknowledgement never repeats an append.
class BuilderCopyInspectionDialog extends StatelessWidget {
  const BuilderCopyInspectionDialog({
    super.key,
    required this.destination,
    required this.content,
  });
  final String destination;
  final String content;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.builderVerifyCopy),
      content: SizedBox(
        width: 700,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(destination),
            Text(l10n.builderVerifyCopyExplanation),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
              child: SingleChildScrollView(child: SelectableText(content)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.builderKeepDraft),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.builderCopyPresent),
        ),
      ],
    );
  }
}
