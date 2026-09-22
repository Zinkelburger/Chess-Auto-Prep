/// The Lichess "New chapter" dialog: a name, where the chapter starts
/// (initial position, a set-up position, or pasted PGN — several games
/// become several chapters) and which side faces the reader.
library;

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';

import '../../constants/chess_constants.dart';
import '../../design_system/theme/app_typography.dart';
import '../../utils/chess_utils.dart' show tryParseFen;
import '../board_editor/board_editor_dialog.dart';

/// What the user asked for.  [name] is empty when they left it to the
/// study ("Chapter N", or the PGN's own chapter tags); [orientation] is
/// null for "automatic" (the PGN's `[Orientation]` tag, else the side to
/// move in a set-up position, else White).
sealed class NewChapterRequest {
  const NewChapterRequest({required this.name, required this.orientation});

  final String name;
  final Side? orientation;
}

/// An empty chapter from the initial position.
final class NewEmptyChapter extends NewChapterRequest {
  const NewEmptyChapter({required super.name, required super.orientation});
}

/// An empty chapter from [fen].
final class NewChapterFromFen extends NewChapterRequest {
  const NewChapterFromFen({
    required super.name,
    required super.orientation,
    required this.fen,
  });

  final String fen;
}

/// One chapter per game in [pgn].
final class NewChaptersFromPgn extends NewChapterRequest {
  const NewChaptersFromPgn({
    required super.name,
    required super.orientation,
    required this.pgn,
  });

  final String pgn;
}

enum _Source { initial, fen, pgn }

/// Ask how to start a new chapter.  [defaultName] is the placeholder the
/// study will use when the name is left blank; [initialFen] pre-selects the
/// set-up-position source (the board the user was looking at).
Future<NewChapterRequest?> showNewChapterDialog(
  BuildContext context, {
  required String defaultName,
  String? initialFen,
}) => showDialog<NewChapterRequest>(
  context: context,
  builder: (_) =>
      _NewChapterDialog(defaultName: defaultName, initialFen: initialFen),
);

class _NewChapterDialog extends StatefulWidget {
  const _NewChapterDialog({required this.defaultName, this.initialFen});

  final String defaultName;
  final String? initialFen;

  @override
  State<_NewChapterDialog> createState() => _NewChapterDialogState();
}

class _NewChapterDialogState extends State<_NewChapterDialog> {
  final _name = TextEditingController();
  late final _fen = TextEditingController(text: widget.initialFen ?? '');
  final _pgn = TextEditingController();

  late _Source _source = widget.initialFen == null
      ? _Source.initial
      : _Source.fen;

  /// null = automatic.
  Side? _orientation;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _fen.dispose();
    _pgn.dispose();
    super.dispose();
  }

  Future<void> _setUpBoard() async {
    final position = await BoardEditorDialog.show(
      context,
      initialFen: tryParseFen(_fen.text.trim()) == null
          ? kStandardStartFen
          : _fen.text.trim(),
      actionLabel: AppLocalizations.of(context).studyUsePosition,
    );
    if (position == null || !mounted) return;
    setState(() {
      _fen.text = position.fen;
      _error = null;
    });
  }

  void _submit() {
    final name = _name.text.trim();
    switch (_source) {
      case _Source.initial:
        Navigator.of(
          context,
        ).pop(NewEmptyChapter(name: name, orientation: _orientation));
      case _Source.fen:
        final fen = _fen.text.trim();
        if (tryParseFen(fen) == null) {
          setState(() => _error = AppLocalizations.of(context).studyInvalidFen);
          return;
        }
        Navigator.of(context).pop(
          NewChapterFromFen(name: name, orientation: _orientation, fen: fen),
        );
      case _Source.pgn:
        final pgn = _pgn.text.trim();
        if (pgn.isEmpty) {
          setState(
            () => _error = AppLocalizations.of(context).studyPasteGameRequired,
          );
          return;
        }
        Navigator.of(context).pop(
          NewChaptersFromPgn(name: name, orientation: _orientation, pgn: pgn),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.studyNewChapter),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.studyName,
                hintText: _source == _Source.pgn
                    ? l10n.studyChapterNameFromPgn
                    : widget.defaultName,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.studyChapterStartFrom,
              style: AppTypography.caption(context),
            ),
            const SizedBox(height: 6),
            SegmentedButton<_Source>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: _Source.initial,
                  label: Text(l10n.studyInitialPosition),
                ),
                ButtonSegment(
                  value: _Source.fen,
                  label: Text(l10n.studyPosition),
                ),
                ButtonSegment(value: _Source.pgn, label: Text(l10n.studyPgn)),
              ],
              selected: {_source},
              onSelectionChanged: (s) => setState(() {
                _source = s.single;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            switch (_source) {
              _Source.initial => const SizedBox.shrink(),
              _Source.fen => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _fen,
                      style: AppTypography.mono(context),
                      decoration: InputDecoration(
                        labelText: l10n.studyFen,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _setUpBoard,
                    child: Text(l10n.studySetupBoard),
                  ),
                ],
              ),
              _Source.pgn => TextField(
                controller: _pgn,
                minLines: 5,
                maxLines: 10,
                style: AppTypography.mono(context),
                decoration: InputDecoration(
                  hintText: l10n.studyPasteChaptersHint,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
            },
            const SizedBox(height: 16),
            Text(l10n.studyOrientation, style: AppTypography.caption(context)),
            const SizedBox(height: 6),
            SegmentedButton<Side?>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: null,
                  label: Text(l10n.studyAutomaticOrientation),
                ),
                ButtonSegment(value: Side.white, label: Text(l10n.white)),
                ButtonSegment(value: Side.black, label: Text(l10n.black)),
              ],
              selected: {_orientation},
              onSelectionChanged: (s) =>
                  setState(() => _orientation = s.single),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: AppTypography.caption(
                  context,
                ).copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(onPressed: _submit, child: Text(l10n.studyCreate)),
      ],
    );
  }
}
