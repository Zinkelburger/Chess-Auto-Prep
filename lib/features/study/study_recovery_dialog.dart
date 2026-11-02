import 'package:flutter/material.dart';

import '../../storage/deleted_chapters.dart';
import '../../ui/attempting.dart';
import '../../ui/list_message.dart';
import '../../ui/name_dialog.dart';
import '../../ui/progress_line.dart';
import '../../ui/theme.dart';
import 'studies.dart';
import 'studies_state.dart';

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

class _RecoveryState extends State<_Recovery> with Attempting<_Recovery> {
  Future<DeletedListing>? _listing;
  @override
  void initState() {
    super.initState();
    _listing = widget.studies.deleted();
  }

  /// The last restore went through.
  bool _restored = false;

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
    setState(() => _restored = false);
    final result = await attempt(
      'restore deleted study',
      action,
      failure: 'Could not confirm the restore. Retry save or refresh the list.',
    );
    if (result == null) return;
    setState(() {
      if (result is StudyProblem) {
        problem = result.sentence;
      } else {
        _restored = true;
      }
      _listing = widget.studies.deleted();
    });
  }

  /// The deleted studies as the listing reads, or why there are none.
  Widget _listingView(
    BuildContext context,
    AsyncSnapshot<DeletedListing> snapshot,
  ) {
    if (snapshot.hasError || snapshot.data is DeletedUnreadable) {
      return ListMessage(
        'Could not read the deleted studies.',
        inset: 0,
        action: OutlinedButton(
          onPressed: busy
              ? null
              : () => setState(() => _listing = widget.studies.deleted()),
          child: const Text('Try again'),
        ),
      );
    }
    final listing = snapshot.data;
    if (listing is! DeletedChapters) {
      return const ListMessage.loading('Reading deleted studies…', inset: 0);
    }
    if (listing.chapters.isEmpty) {
      return const ListMessage('No deleted studies.', inset: 0);
    }
    return ListView.builder(
      itemCount: listing.chapters.length,
      itemBuilder: (context, index) => _row(context, listing.chapters[index]),
    );
  }

  /// One deleted study with when it went, and its two ways back.
  Widget _row(BuildContext context, DeletedChapter chapter) {
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
            onPressed: busy ? null : () => _restore(chapter),
            child: const Text('Restore'),
          ),
          TextButton(
            onPressed: busy ? null : () => _restore(chapter, rename: true),
            child: const Text('Restore as…'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Deleted studies'),
      content: SizedBox(
        width: dialogWide,
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Restore a study with all its chapters and annotations.',
            ),
            ProgressLine(active: busy),
            if (problem ?? (_restored ? 'Study restored.' : null)
                case final message?)
              Semantics(liveRegion: true, child: Text(message)),
            if (widget.studies.canRetryRestore)
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _run(widget.studies.retryRestore),
                child: const Text('Retry save'),
              ),
            const SizedBox(height: Space.s),
            Expanded(
              child: FutureBuilder<DeletedListing>(
                future: _listing,
                builder: _listingView,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() => _listing = widget.studies.deleted()),
          child: const Text('Refresh'),
        ),
      ],
    ),
  );
}
