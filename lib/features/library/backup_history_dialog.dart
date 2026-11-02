import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/backup_history.dart';
import '../../storage/backups.dart';
import '../../storage/chapter_files.dart';
import '../../ui/attempting.dart';
import '../../ui/form_dialog.dart';
import '../../ui/list_message.dart';
import '../../ui/theme.dart';

/// Pick and inspect exact archived PGN before restoring it as a separate copy.
Future<String?> showBackupHistory(
  BuildContext context,
  BackupHistory history,
  ChapterRef ref,
) => showDialog<String>(
  context: context,
  builder: (_) => _History(history: history, ref: ref),
);

class _History extends StatefulWidget {
  const _History({required this.history, required this.ref});
  final BackupHistory history;
  final ChapterRef ref;
  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> with Attempting<_History> {
  List<BackupVersion> _versions = const [];
  BackupVersion? _selected;
  String? _text;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final versions = await attempt(
      'read version history',
      () => widget.history.versions(widget.ref),
      failure: 'Could not read the version history.',
    );
    if (versions != null) setState(() => _versions = versions);
  }

  Future<void> _select(BackupVersion version) async {
    setState(() {
      _selected = version;
      _text = null;
    });
    final text = await attempt(
      'read archived version',
      () => widget.history.text(widget.ref, version),
      failure: 'Could not read this version.',
    );
    if (text != null) setState(() => _text = text);
  }

  Future<void> _prune() async {
    setState(() {
      _text = null;
      _selected = null;
    });
    final versions = await attempt('delete older versions', () async {
      await widget.history.prune(widget.ref);
      return widget.history.versions(widget.ref);
    }, failure: 'Could not delete the older versions.');
    if (versions != null) setState(() => _versions = versions);
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: 'Version history · ${widget.ref.fileName}',
    width: dialogWide,
    working: busy,
    canFail: true,
    problem: problem,
    confirm: 'Restore as new repertoire',
    onConfirm: busy || _text == null
        ? null
        : () => Navigator.pop(context, _text),
    body: SizedBox(
      height: dialogListHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Restore a version as a new repertoire to inspect its chapters and lines.',
          ),
          const SizedBox(height: Space.s),
          Expanded(
            // Both sides start at the top, as every list does.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: dialogSideListWidth,
                  child: _versions.isEmpty
                      ? const ListMessage('No earlier versions.', inset: 0)
                      : ListView.builder(
                          itemCount: _versions.length,
                          itemBuilder: (_, index) {
                            final v = _versions[index];
                            return ListTile(
                              dense: true,
                              selected: _selected == v,
                              title: Text(
                                v.time.toLocal().toString().split('.').first,
                              ),
                              subtitle: Text('${v.size} bytes'),
                              onTap: busy ? null : () => _select(v),
                            );
                          },
                        ),
                ),
                const VerticalDivider(),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _text ?? 'Select a version to preview its PGN.',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Text(
            'Cleanup keeps the newest 100 versions and all versions from the last 90 days.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy || _versions.length <= 100 ? null : _prune,
              child: const Text('Delete older versions beyond those limits'),
            ),
          ),
        ],
      ),
    ),
  );
}
