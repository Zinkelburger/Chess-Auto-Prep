/// Dialog for exporting the lines found so far by an in-progress generation
/// run into a **new** repertoire.  Mid-run snapshots never append to an
/// existing repertoire — mixing lines from different depths in one file
/// would make them contradict each other — so the only inputs are the new
/// repertoire's name and whether to engine-verify before export.
library;

import 'package:flutter/material.dart';

import '../../services/storage/storage_factory.dart';

class SnapshotExportChoice {
  final String name;
  final bool verify;

  const SnapshotExportChoice({required this.name, required this.verify});
}

/// Returns the chosen name + verify flag, or null on cancel.
Future<SnapshotExportChoice?> showSnapshotExportDialog(
  BuildContext context, {
  required String suggestedName,
  required bool canVerify,
  int? verifyDepth,
}) async {
  final nameController = TextEditingController(text: suggestedName);
  String? nameError;
  bool verify = canVerify;
  bool checking = false;

  final result = await showDialog<SnapshotExportChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> submit() async {
          final name = nameController.text.trim();
          if (name.isEmpty) {
            setState(() => nameError = 'Please enter a name');
            return;
          }
          setState(() => checking = true);
          final storage = StorageFactory.instance;
          final path = await storage.repertoireFilePath(name);
          final exists = await storage.fileExists(path);
          if (!context.mounted) return;
          if (exists) {
            setState(() {
              checking = false;
              nameError = 'A repertoire named "$name" already exists';
            });
            return;
          }
          Navigator.of(
            context,
          ).pop(SnapshotExportChoice(name: name, verify: verify));
        }

        return AlertDialog(
          title: const Text('Export Lines So Far'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Saves the lines found so far to a new repertoire. '
                'The build keeps running.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'New repertoire name',
                  errorText: nameError,
                ),
                autofocus: true,
                onChanged: (_) {
                  if (nameError != null) setState(() => nameError = null);
                },
                onSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: verify,
                onChanged: canVerify
                    ? (v) => setState(() => verify = v ?? false)
                    : null,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Verify with engine before export'),
                subtitle: Text(
                  canVerify
                      ? 'Re-checks the chosen moves'
                            '${verifyDepth != null ? ' at depth $verifyDepth' : ''}. '
                            'Exploration pauses while verifying, then resumes.'
                      : 'Not available for this build mode.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: checking ? null : submit,
              child: const Text('Export'),
            ),
          ],
        );
      },
    ),
  );

  nameController.dispose();
  return result;
}
