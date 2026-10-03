import 'package:flutter/material.dart';

import '../../storage/chapter_files.dart';
import '../../ui/name_dialog.dart';
import '../../ui/theme.dart';
import 'studies.dart';

Future<void> showStudyRecovery(BuildContext context, Studies studies) =>
    showDialog<void>(
      context: context,
      builder: (_) => _Recovery(studies: studies),
    );

class _Recovery extends StatefulWidget {
  const _Recovery({required this.studies});
  final Studies studies;
  @override
  State<_Recovery> createState() => _RecoveryState();
}

class _RecoveryState extends State<_Recovery> {
  Future<DeletedListing>? _listing;
  @override
  void initState() {
    super.initState();
    _listing = widget.studies.deleted();
  }

  bool _busy = false;
  String? _message;

  Future<void> _restore(DeletedChapter chapter, {bool rename = false}) async {
    final name = rename
        ? await showNameDialog(
            context,
            title: 'Restore study as',
            label: 'Study name',
            confirm: 'Restore',
          )
        : null;
    if (!mounted || (rename && name == null)) return;
    await _run(() => widget.studies.restore(chapter, name: name));
  }

  Future<void> _run(Future<StudyResult> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() {
        _message = result is StudyProblem ? result.sentence : 'Study restored.';
        _listing = widget.studies.deleted();
      });
    } catch (_) {
      if (mounted)
        setState(
          () => _message =
              'Could not confirm the restore. Retry restore or refresh the list.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Deleted studies'),
      content: SizedBox(
        width: nameDialogWidth * 2,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Restore a study with all its chapters and annotations.',
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_message != null)
              Semantics(liveRegion: true, child: Text(_message!)),
            if (widget.studies.canRetryRestore)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(widget.studies.retryRestore),
                child: const Text('Retry restore'),
              ),
            const SizedBox(height: Space.s),
            Expanded(
              child: FutureBuilder<DeletedListing>(
                future: _listing,
                builder: (context, snapshot) {
                  if (snapshot.hasError || snapshot.data is DeletedUnreadable) {
                    return const Center(
                      child: Text(
                        'Could not read deleted studies. Try Refresh.',
                      ),
                    );
                  }
                  final listing = snapshot.data;
                  if (listing is! DeletedChapters)
                    return const Center(child: CircularProgressIndicator());
                  if (listing.chapters.isEmpty)
                    return const Center(child: Text('No deleted studies.'));
                  return ListView.builder(
                    itemCount: listing.chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = listing.chapters[index];
                      final date = MaterialLocalizations.of(
                        context,
                      ).formatShortDate(chapter.deletedAt.toLocal());
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.xs),
                        child: Row(
                          children: [
                            Expanded(
                              child: Tooltip(
                                message: chapter.name,
                                child: Text(
                                  '${chapter.name}\n$date',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _busy ? null : () => _restore(chapter),
                              child: const Text('Restore'),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _restore(chapter, rename: true),
                              child: const Text('Restore as…'),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _listing = widget.studies.deleted()),
          child: const Text('Refresh'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
