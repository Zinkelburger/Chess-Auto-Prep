/// Metadata controls for the board editor: side to move, castling rights,
/// en passant, FEN in/out, clear/start shortcuts, and a caller-labelled
/// primary action gated on position validity.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import 'package:flutter/services.dart';

import '../../core/board_editor_controller.dart';
import '../common/choice_field.dart';
import '../../design_system/theme/app_typography.dart';
import '../copy_button.dart';
import '../labeled_toggle.dart';

class PositionSetupPanel extends StatefulWidget {
  final BoardEditorController controller;

  /// Label for the primary action button (e.g. "Use position",
  /// "Record solution").  Hidden when null.
  final String? actionLabel;

  /// Invoked with the validated position when the action button is pressed.
  final void Function(Position position)? onAction;

  /// Collapse castling and en passant when embedding in a compact flow.
  final bool advancedInitiallyExpanded;

  /// Disable internal scrolling when hosted by [SingleChildScrollView].
  final bool scrollable;

  const PositionSetupPanel({
    super.key,
    required this.controller,
    this.actionLabel,
    this.onAction,
    this.advancedInitiallyExpanded = true,
    this.scrollable = true,
  });

  @override
  State<PositionSetupPanel> createState() => _PositionSetupPanelState();
}

class _PositionSetupPanelState extends State<PositionSetupPanel> {
  late final TextEditingController _fenCtrl;
  String? _fenError;

  BoardEditorController get _editor => widget.controller;

  @override
  void initState() {
    super.initState();
    _fenCtrl = TextEditingController(text: _editor.fenInput);
    _editor.addListener(_onEditorChanged);
  }

  @override
  void didUpdateWidget(covariant PositionSetupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onEditorChanged);
    _editor.addListener(_onEditorChanged);
    _fenCtrl.text = _editor.fenInput;
    _fenError = null;
  }

  @override
  void dispose() {
    _editor.removeListener(_onEditorChanged);
    _fenCtrl.dispose();
    super.dispose();
  }

  void _onEditorChanged() {
    if (!mounted) return;
    if (_fenCtrl.text != _editor.fenInput) {
      _fenCtrl.text = _editor.fenInput;
    }
    if (!_editor.hasUnappliedFen) _fenError = null;
    setState(() {});
  }

  void _applyFenInput(String value) {
    if (!mounted) return;
    _editor.setFenDraft(value);
    if (!_editor.loadFen(value)) {
      if (!mounted) return;
      setState(() => _fenError = AppLocalizations.of(context).boardInvalidFen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _editor.validationError;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Side to move + board shortcuts ─────────────────────────
        // The panel is the narrow half of the editor dialog (~380px), and
        // a SegmentedButton will not shrink its own labels, so scale it
        // down rather than overflow.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: SegmentedButton<Side>(
            segments: [
              ButtonSegment(
                value: Side.white,
                label: Text(AppLocalizations.of(context).boardWhiteToMove),
              ),
              ButtonSegment(
                value: Side.black,
                label: Text(AppLocalizations.of(context).boardBlackToMove),
              ),
            ],
            selected: {_editor.turn},
            onSelectionChanged: (sel) {
              if (!mounted) return;
              _editor.setTurn(sel.first);
            },
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.replay, size: 16),
              label: Text(AppLocalizations.of(context).boardStartPosition),
              onPressed: _editor.setStartPosition,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.clear, size: 16),
              label: Text(AppLocalizations.of(context).boardClear),
              onPressed: _editor.clear,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.swap_vert, size: 16),
              label: Text(AppLocalizations.of(context).studyFlipBoard),
              onPressed: _editor.toggleFlip,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          AppLocalizations.of(context).boardSetupHelp,
          style: AppTypography.caption(context),
        ),
        const SizedBox(height: 12),

        // ── Castling rights ────────────────────────────────────────
        ExpansionTile(
          title: Text(AppLocalizations.of(context).boardAdvanced),
          subtitle: Text(AppLocalizations.of(context).boardCastlingEnPassant),
          initiallyExpanded: widget.advancedInitiallyExpanded,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.of(context).boardCastling,
              style: theme.textTheme.labelLarge,
            ),
            Row(
              children: [
                _castleBox(
                  AppLocalizations.of(
                    context,
                  ).boardCastleSide(AppLocalizations.of(context).white, 'O-O'),
                  _editor.whiteKingside,
                  _editor.whiteKingsideAllowed,
                  _editor.setWhiteKingside,
                ),
                _castleBox(
                  AppLocalizations.of(context).boardCastleSide(
                    AppLocalizations.of(context).white,
                    'O-O-O',
                  ),
                  _editor.whiteQueenside,
                  _editor.whiteQueensideAllowed,
                  _editor.setWhiteQueenside,
                ),
              ],
            ),
            Row(
              children: [
                _castleBox(
                  AppLocalizations.of(
                    context,
                  ).boardCastleSide(AppLocalizations.of(context).black, 'O-O'),
                  _editor.blackKingside,
                  _editor.blackKingsideAllowed,
                  _editor.setBlackKingside,
                ),
                _castleBox(
                  AppLocalizations.of(context).boardCastleSide(
                    AppLocalizations.of(context).black,
                    'O-O-O',
                  ),
                  _editor.blackQueenside,
                  _editor.blackQueensideAllowed,
                  _editor.setBlackQueenside,
                ),
              ],
            ),

            // ── En passant ─────────────────────────────────────────────
            if (_editor.epCandidates.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    AppLocalizations.of(context).boardEnPassant,
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 120,
                    child: ChoiceField<Square?>(
                      value: _editor.epSquare,
                      compact: true,
                      items: [
                        ChoiceItem(
                          value: null,
                          label: AppLocalizations.of(context).boardNoEnPassant,
                        ),
                        for (final sq in _editor.epCandidates)
                          ChoiceItem(value: sq, label: sq.name),
                      ],
                      onChanged: _editor.setEpSquare,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        // ── FEN in/out ─────────────────────────────────────────────
        TextField(
          controller: _fenCtrl,
          style: AppTypography.mono(context),
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: 'FEN',
            errorText: _fenError,
            helperText: _editor.hasUnappliedFen
                ? AppLocalizations.of(context).boardFenPending
                : null,
            helperMaxLines: 2,
            errorMaxLines: 2,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CopyButton.icon(
                  tooltip: AppLocalizations.of(context).boardCopyFen,
                  iconSize: 16,
                  snackBarMessage: AppLocalizations.of(context).boardFenCopied,
                  text: () => _editor.fen,
                ),
                IconButton(
                  icon: const Icon(Icons.content_paste, size: 16),
                  tooltip: AppLocalizations.of(context).boardPasteFen,
                  onPressed: () async {
                    final editor = _editor;
                    final data = await Clipboard.getData('text/plain');
                    if (!mounted || editor != _editor) return;
                    final text = data?.text;
                    if (text != null && text.trim().isNotEmpty && mounted) {
                      _applyFenInput(text);
                    }
                  },
                ),
              ],
            ),
          ),
          onChanged: (value) {
            if (!mounted) return;
            setState(() => _fenError = null);
            _editor.setFenDraft(value);
          },
          onSubmitted: _applyFenInput,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: _editor.hasUnappliedFen
                  ? () => _applyFenInput(_fenCtrl.text)
                  : null,
              child: Text(AppLocalizations.of(context).boardApplyFen),
            ),
            if (_editor.hasUnappliedFen)
              TextButton(
                onPressed: _editor.discardFenDraft,
                child: Text(AppLocalizations.of(context).boardDiscardFen),
              ),
          ],
        ),

        // ── Validation + action ────────────────────────────────────
        if (error != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.warning_amber,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (widget.actionLabel != null) ...[
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _editor.validPosition == null || widget.onAction == null
                ? null
                : () {
                    if (!mounted) return;
                    final position = _editor.validPosition;
                    if (position != null) widget.onAction?.call(position);
                  },
            child: Text(widget.actionLabel!),
          ),
        ],
      ],
    );
    return widget.scrollable ? SingleChildScrollView(child: content) : content;
  }

  Widget _castleBox(
    String label,
    bool value,
    bool allowed,
    ValueChanged<bool> onChanged,
  ) {
    return Expanded(
      child: AppCheckbox(
        label: label,
        value: value,
        onChanged: onChanged,
        enabled: allowed,
      ),
    );
  }
}
