import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/backup_history.dart';
import '../../storage/backups.dart';
import '../../storage/chapter_files.dart';
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

class _HistoryState extends State<_History> {
  List<BackupVersion> _versions = const [];
  BackupVersion? _selected;
  String? _text;
  String? _problem;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final versions = await widget.history.versions(widget.ref);
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _busy = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _problem = '$error';
          _busy = false;
        });
      }
    }
  }

  Future<void> _select(BackupVersion version) async {
    setState(() {
      _selected = version;
      _text = null;
      _problem = null;
      _busy = true;
    });
    try {
      final text = await widget.history.text(widget.ref, version);
      if (!mounted) return;
      setState(() {
        _text = text;
        _busy = false;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _problem = '$error';
          _busy = false;
        });
      }
    }
  }

  Future<void> _prune() async {
    setState(() {
      _busy = true;
      _text = null;
      _selected = null;
    });
    try {
      await widget.history.prune(widget.ref);
      await _load();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _problem = '$error';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: 'Version history · ${widget.ref.fileName}',
    width: dialogWide,
    working: _busy,
    canFail: true,
    problem: _problem,
    confirm: 'Restore as new repertoire',
    onConfirm: _busy || _text == null
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
            child: Row(
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
                              onTap: _busy ? null : () => _select(v),
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
              onPressed: _busy || _versions.length <= 100 ? null : _prune,
              child: const Text('Delete older versions beyond those limits'),
            ),
          ),
        ],
      ),
    ),
  );
}
