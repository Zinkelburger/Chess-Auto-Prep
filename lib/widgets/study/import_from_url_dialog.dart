/// "Import from URL…" — paste a Lichess study or a chessgames.com collection
/// link and turn it into a study.
///
/// The dialog resolves the source before it closes, so problems (a private
/// study, a blocked collection page) are shown inline where they can still be
/// acted on. It hands back a [StudyImportPlan]; the Study screen applies it —
/// Lichess arrives whole and imports instantly, a collection is a long paced
/// download and goes to [StudyImportController].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/lichess_auth_service.dart';
import '../../services/study_import/chessgames_collection_client.dart';
import '../../services/study_import/import_source.dart';
import '../../services/study_import/lichess_study_client.dart';
import '../../services/study_import/study_import_controller.dart';
import '../../services/study_import/study_import_exception.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../labeled_toggle.dart';

/// What the user asked for, resolved and ready to apply.
sealed class StudyImportPlan {
  const StudyImportPlan();
}

/// A Lichess study, already downloaded — nothing left but to file it.
class LichessStudyPlan extends StudyImportPlan {
  const LichessStudyPlan({
    required this.pgn,
    required this.name,
    required this.appendToCurrent,
  });

  final String pgn;
  final String name;

  /// Append the chapters to the open study instead of creating a new one.
  final bool appendToCurrent;
}

/// A chessgames.com collection with its game ids resolved. The download itself
/// has not started — it takes minutes and belongs in the background.
class CollectionPlan extends StudyImportPlan {
  const CollectionPlan({
    required this.gameIds,
    required this.studyName,
    required this.delay,
  });

  final List<String> gameIds;
  final String studyName;
  final Duration delay;
}

class ImportFromUrlDialog extends StatefulWidget {
  const ImportFromUrlDialog({super.key, required this.canAppend});

  /// Whether there is an open study to append to.
  final bool canAppend;

  /// Show the dialog. Resolves to `null` if dismissed.
  static Future<StudyImportPlan?> show(
    BuildContext context, {
    required bool canAppend,
  }) {
    return showDialog<StudyImportPlan>(
      context: context,
      builder: (_) => ImportFromUrlDialog(canAppend: canAppend),
    );
  }

  @override
  State<ImportFromUrlDialog> createState() => _ImportFromUrlDialogState();
}

class _ImportFromUrlDialogState extends State<ImportFromUrlDialog> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _delayController = TextEditingController(
    text: '${StudyImportController.defaultDelay.inSeconds}',
  );

  ImportSource? _source;
  bool _appendToCurrent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _delayController.dispose();
    super.dispose();
  }

  bool get _isLichess =>
      _source is LichessStudySource || _source is LichessUserStudiesSource;

  /// A collection always becomes its own study: the download runs in the
  /// background and could otherwise land in whichever study is open by then.
  bool get _canAppend => widget.canAppend && _isLichess;

  void _onUrlChanged(String value) {
    setState(() {
      _source = parseImportSource(value);
      _error = null;
    });
  }

  Duration get _delay {
    final seconds = int.tryParse(_delayController.text.trim());
    return seconds == null || seconds <= 0
        ? StudyImportController.defaultDelay
        : Duration(seconds: seconds);
  }

  Future<void> _import() async {
    final source = _source;
    if (source == null || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final plan = switch (source) {
        LichessStudySource() ||
        LichessUserStudiesSource() => await _resolveLichess(source),
        ChessgamesCollectionSource() => await _resolveCollection(source),
      };
      if (!mounted || plan == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      Navigator.pop(context, plan);
    } on StudyImportException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  Future<StudyImportPlan?> _resolveLichess(ImportSource source) async {
    final study = await fetchLichessStudy(source);
    return LichessStudyPlan(
      pgn: study.pgn,
      name: study.name,
      appendToCurrent: _canAppend && _appendToCurrent,
    );
  }

  Future<StudyImportPlan?> _resolveCollection(
    ChessgamesCollectionSource source,
  ) async {
    final html = await fetchCollectionHtml(source.cid);
    var ids = html == null ? <String>[] : extractCollectionGameIds(html);
    var name =
        (html == null ? null : extractCollectionTitle(html)) ??
        'Collection ${source.cid}';

    // No ids means the AWS WAF served a challenge page instead of the
    // collection. The PGN endpoint itself is usually still reachable, so ask
    // for the ids rather than giving up on the import.
    if (ids.isEmpty) {
      if (!mounted) return null;
      final pasted = await _PasteGameIdsDialog.show(context, cid: source.cid);
      if (pasted == null || pasted.isEmpty) return null;
      ids = pasted;
    }

    return CollectionPlan(gameIds: ids, studyName: name, delay: _delay);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import from URL'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'lichess.org/study/<id>  —  one study, all chapters\n'
              'lichess.org/study/by/<user>  —  every public study of theirs\n'
              'chessgames.com/perl/chesscollection?cid=<id>  —  a collection',
              style: AppTextStyles.caption,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              autofocus: true,
              enabled: !_busy,
              onChanged: _onUrlChanged,
              onSubmitted: (_) => _import(),
              decoration: const InputDecoration(
                labelText: 'URL',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            _statusLine(),
            const Divider(height: 24),
            AppCheckbox(
              label: 'Add to the current study instead of creating a new one',
              value: _canAppend && _appendToCurrent,
              enabled: _canAppend && !_busy,
              disabledReason: widget.canAppend
                  ? 'A chessgames.com collection downloads in the background '
                        'and always gets its own study.'
                  : 'No study is open.',
              onChanged: (v) => setState(() => _appendToCurrent = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Seconds between requests (chessgames.com)',
                    style: AppTextStyles.body,
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: TextField(
                    controller: _delayController,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'chessgames.com bans fast downloads: 2–3 s apart gets blocked '
              'after ~20 games, 22 s apart sustains 60. At 22 s a 60-game '
              'collection takes about 25 minutes, running in the background.',
              style: AppTextStyles.caption,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _source == null || _busy ? null : _import,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Import'),
        ),
      ],
    );
  }

  /// Fixed-height feedback row, so recognising a URL never shifts the layout.
  Widget _statusLine() {
    final String text;
    final Color color;
    final source = _source;
    if (_error != null) {
      (text, color) = (_error!, AppColors.danger);
    } else if (_busy) {
      (text, color) = ('Contacting the server…', AppColors.onSurfaceMuted);
    } else if (source != null) {
      (text, color) = (source.label, AppColors.success);
    } else if (_urlController.text.trim().isEmpty) {
      (text, color) = (
        'Paste a link to see what will be imported.',
        AppColors.onSurfaceMuted,
      );
    } else {
      (text, color) = (
        'Not a Lichess study or chessgames.com collection link.',
        AppColors.warning,
      );
    }

    return SizedBox(
      height: 34,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: AppTextStyles.caption.copyWith(color: color),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

// ── WAF fallback ─────────────────────────────────────────────────────────

/// Asked for when the collection page comes back as an AWS WAF challenge
/// instead of HTML: the game ids have to come from a real browser.
///
/// Accepts anything that contains them — saved page source, a list of game
/// URLs, or bare ids one per line.
class _PasteGameIdsDialog extends StatefulWidget {
  const _PasteGameIdsDialog({required this.cid});

  final String cid;

  static Future<List<String>?> show(
    BuildContext context, {
    required String cid,
  }) {
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _PasteGameIdsDialog(cid: cid),
    );
  }

  @override
  State<_PasteGameIdsDialog> createState() => _PasteGameIdsDialogState();
}

class _PasteGameIdsDialogState extends State<_PasteGameIdsDialog> {
  final TextEditingController _controller = TextEditingController();
  List<String> _ids = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final ids = parsePastedGameIds(value);
    if (ids.length == _ids.length) return;
    setState(() => _ids = ids);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Collection page blocked'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'chessgames.com served a bot check instead of the collection. '
              'Downloading the games still works — it just needs the list.\n\n'
              'Open the collection in a browser, select all (Ctrl+A) and copy, '
              'or save the page source, then paste it below.',
              style: AppTextStyles.body,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => LichessAuthService.openUrl(
                  'https://www.chessgames.com/perl/chesscollection'
                  '?cid=${widget.cid}',
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open the collection page'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 5,
              maxLines: 10,
              onChanged: _onChanged,
              style: const TextStyle(fontFamily: 'SourceCodePro', fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'Paste the page, game links, or game ids…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 20,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _ids.isEmpty
                      ? 'No game ids found yet.'
                      : '${_ids.length} game${_ids.length == 1 ? '' : 's'} '
                            'found.',
                  style: AppTextStyles.caption.copyWith(
                    color: _ids.isEmpty
                        ? AppColors.onSurfaceMuted
                        : AppColors.success,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ids.isEmpty ? null : () => Navigator.pop(context, _ids),
          child: Text(_ids.isEmpty ? 'Download' : 'Download ${_ids.length}'),
        ),
      ],
    );
  }
}
