/// "Import from URL…" — paste a Lichess study or a chessgames.com collection
/// link and turn it into a study.
///
/// The dialog resolves the source before it closes, so problems (a private
/// study, a blocked collection page) are shown inline where they can still be
/// acted on. It hands back a [StudyImportPlan]; the Study screen applies it —
/// Lichess arrives whole and imports instantly, a collection is a long paced
/// download and goes to [StudyImportController].
library;

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/study_import_labels.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';

import '../../services/lichess_auth_service.dart';
import '../../features/studies/repositories/study_import_repository.dart';
import '../../features/studies/models/import_source.dart';
import '../../features/studies/controllers/study_import_controller.dart';
import '../../features/studies/models/study_import_exception.dart';
import '../../design_system/theme/app_typography.dart';
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
  const ImportFromUrlDialog({
    super.key,
    required this.canAppend,
    required this.repository,
    required this.apply,
  });

  final StudyImportRepository repository;

  /// False keeps the resolved download here for retry; true means an app owner
  /// has accepted its bytes, including an uncertain publication or dirty append.
  final Future<bool> Function(StudyImportPlan) apply;

  /// Whether there is an open study to append to.
  final bool canAppend;

  /// Show the dialog. Resolves to `null` if dismissed.
  static Future<StudyImportPlan?> show(
    BuildContext context, {
    required bool canAppend,
    required StudyImportRepository repository,
    required Future<bool> Function(StudyImportPlan) apply,
  }) {
    return showDialog<StudyImportPlan>(
      context: context,
      builder: (_) => ImportFromUrlDialog(
        canAppend: canAppend,
        repository: repository,
        apply: apply,
      ),
    );
  }

  @override
  State<ImportFromUrlDialog> createState() => _ImportFromUrlDialogState();
}

class _ImportFromUrlDialogState extends State<ImportFromUrlDialog> {
  late final StudyImportSource _network = widget.repository.openSource();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _delayController = TextEditingController(
    text: '${StudyImportController.defaultDelay.inSeconds}',
  );

  ImportSource? _source;
  StudyImportPlan? _resolvedPlan;
  bool _appendToCurrent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _network.close();
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
      _resolvedPlan = null;
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
      final plan = _resolvedPlan ??= switch (source) {
        LichessStudySource() ||
        LichessUserStudiesSource() => await _resolveLichess(source),
        ChessgamesCollectionSource() => await _resolveCollection(source),
      };
      if (!mounted || plan == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final submitted = switch (plan) {
        LichessStudyPlan() => LichessStudyPlan(
          pgn: plan.pgn,
          name: plan.name,
          appendToCurrent: _canAppend && _appendToCurrent,
        ),
        CollectionPlan() => CollectionPlan(
          gameIds: plan.gameIds,
          studyName: plan.studyName,
          delay: _delay,
        ),
      };
      if (await widget.apply(submitted)) {
        if (mounted) Navigator.pop(context, submitted);
      } else if (mounted) {
        setState(() {
          _busy = false;
          _error = AppLocalizations.of(context).studyImportNotAccepted;
        });
      }
    } on StudyImportException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = studySourceFailureLabel(AppLocalizations.of(context), e);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = AppLocalizations.of(context).studyImportDownloadFailed;
        });
      }
    }
  }

  Future<StudyImportPlan?> _resolveLichess(ImportSource source) async {
    final study = await _network.fetchLichess(source);
    return LichessStudyPlan(
      pgn: study.pgn,
      name: study.name,
      appendToCurrent: _canAppend && _appendToCurrent,
    );
  }

  Future<StudyImportPlan?> _resolveCollection(
    ChessgamesCollectionSource source,
  ) async {
    final collection = await _network.fetchCollection(source.cid);
    var ids = collection.gameIds;
    final name = collection.name;

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
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.studyImportFromUrl),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.studyImportSupportedUrls,
              style: AppTypography.caption(context),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              autofocus: true,
              enabled: !_busy,
              onChanged: _onUrlChanged,
              onSubmitted: (_) => _import(),
              decoration: InputDecoration(
                labelText: l10n.studyUrl,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            _statusLine(),
            const Divider(height: 24),
            AppCheckbox(
              label: l10n.studyImportAppend,
              value: _canAppend && _appendToCurrent,
              enabled: _canAppend && !_busy,
              disabledReason: widget.canAppend
                  ? l10n.studyImportCollectionSeparate
                  : l10n.studyImportNoOpenStudy,
              onChanged: (v) => setState(() => _appendToCurrent = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.studyImportDelay,
                    style: AppTypography.body(context),
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
            Text(
              l10n.studyImportDelayHelp,
              style: AppTypography.caption(context),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _source == null || _busy ? null : _import,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.importAction),
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
      (text, color) = (_error!, Theme.of(context).colorScheme.error);
    } else if (_busy) {
      (text, color) = (
        AppLocalizations.of(context).studyImportContacting,
        Theme.of(context).colorScheme.onSurfaceVariant,
      );
    } else if (source != null) {
      (text, color) = (
        switch (source) {
          LichessStudySource(
            :final studyId,
            chapterId: final String chapterId,
          ) =>
            AppLocalizations.of(
              context,
            ).studyLichessChapterSource(studyId, chapterId),
          LichessStudySource(:final studyId) => AppLocalizations.of(
            context,
          ).studyLichessSource(studyId),
          LichessUserStudiesSource(:final username) => AppLocalizations.of(
            context,
          ).studyLichessUserSource(username),
          ChessgamesCollectionSource(:final cid) => AppLocalizations.of(
            context,
          ).studyCollectionSource(cid),
        },
        Theme.of(context).colorScheme.tertiary,
      );
    } else if (_urlController.text.trim().isEmpty) {
      (text, color) = (
        AppLocalizations.of(context).studyImportLinkHint,
        Theme.of(context).colorScheme.onSurfaceVariant,
      );
    } else {
      (text, color) = (
        AppLocalizations.of(context).studyImportUnsupportedUrl,
        Theme.of(context).colorScheme.tertiary,
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 34),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: AppTypography.caption(context).copyWith(color: color),
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
    if (listEquals(ids, _ids)) return;
    setState(() => _ids = ids);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.studyImportCollectionBlocked),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.studyImportPasteIdsHelp,
              style: AppTypography.body(context),
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
                label: Text(l10n.studyImportOpenCollection),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 5,
              maxLines: 10,
              onChanged: _onChanged,
              style: AppTypography.mono(context),
              decoration: InputDecoration(
                hintText: l10n.studyImportPasteIdsHint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _ids.isEmpty
                      ? l10n.studyImportNoIds
                      : l10n.studyImportGamesFound(_ids.length),
                  style: AppTypography.caption(context).copyWith(
                    color: _ids.isEmpty
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.tertiary,
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
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _ids.isEmpty ? null : () => Navigator.pop(context, _ids),
          child: Text(
            _ids.isEmpty
                ? l10n.studyDownload
                : l10n.studyDownloadCount(_ids.length),
          ),
        ),
      ],
    );
  }
}
