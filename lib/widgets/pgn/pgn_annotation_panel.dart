/// Persistent annotation panel shown at the bottom of the PGN viewer while
/// amend mode is active (ChessBase / Lichess-study style): the move the board
/// currently sits on — mainline or sideline — is always the target. Click a
/// move, type in the comment field, toggle glyphs; no extra "edit" click.
library;

import '../../utils/pgn_nags.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import 'package:flutter/services.dart';

import '../../design_system/theme/app_typography.dart';
import 'movetext_primitives.dart' show GlyphButton;
import '../../design_system/components/confirm_dialog.dart';

class PgnAnnotationPanel extends StatefulWidget {
  /// Focuses the comment field of the most recently mounted panel that has a
  /// target move, placing the cursor at the end. Returns false when no such
  /// panel is on screen, so callers can let the key event fall through.
  /// Escape inside the field hands focus back to whoever had it before.
  static bool focusActive() {
    for (final state in PgnAnnotationPanelState._mounted.reversed) {
      if (state.mounted && state.widget.targetKey != null) {
        state._focusComment();
        return true;
      }
    }
    return false;
  }

  /// Identity of the annotated move. When it changes the comment field is
  /// re-seeded from [comment]; null means no move is selected (game start).
  final String? targetKey;

  /// Display label of the target move, e.g. `12...Nf6`.
  final String moveLabel;

  /// Current NAG ids on the target move.
  final List<int> nags;

  /// Current comment text of the target move.
  final String comment;

  final ValueChanged<int> onToggleNag;
  final ValueChanged<String> onCommentChanged;

  /// Whether the glyph strip is live.  False when the target is a position
  /// rather than a move (a chapter's start), which can carry a comment but
  /// not a `!?`.
  final bool glyphsEnabled;

  /// Tree editors commit immediately; PGN-file hosts debounce serialization.
  final Duration commentDebounce;

  /// Builder workspaces disclose notes on demand to leave room for notation.
  final bool compact;

  const PgnAnnotationPanel({
    super.key,
    required this.targetKey,
    required this.moveLabel,
    required this.nags,
    required this.comment,
    required this.onToggleNag,
    required this.onCommentChanged,
    this.glyphsEnabled = true,
    this.compact = false,
    this.commentDebounce = const Duration(milliseconds: 400),
  });

  @override
  State<PgnAnnotationPanel> createState() => PgnAnnotationPanelState();
}

class PgnAnnotationPanelState extends State<PgnAnnotationPanel> {
  /// Mounted panels, oldest first; [PgnAnnotationPanel.focusActive] targets
  /// the newest so a nested/foreground panel wins over a background one.
  static final List<PgnAnnotationPanelState> _mounted = [];

  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnAnnotationPanel');
  Timer? _debounce;
  bool _confirmingDelete = false;
  bool _expanded = false;

  bool get _hasComment => widget.comment.trim().isNotEmpty;
  bool get _blankReplacement => _hasComment && _controller.text.trim().isEmpty;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.comment);
    _focusNode.onKeyEvent = _handleFieldKey;
    _mounted.add(this);
  }

  /// Escape leaves the comment field and returns focus to the previously
  /// focused node (the screen's shortcut Focus), re-enabling board shortcuts.
  KeyEventResult _handleFieldKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _flushDebounce(widget.onCommentChanged);
      node.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusComment() {
    if (widget.compact && !_expanded) {
      setState(() => _expanded = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusComment();
      });
      return;
    }
    _focusNode.requestFocus();
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  @override
  void didUpdateWidget(PgnAnnotationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetKey != oldWidget.targetKey) {
      // New target: flush any pending edit for the old one, then re-seed.
      _flushDebounce(oldWidget.onCommentChanged);
      _controller.text = widget.comment;
    } else if (!_focusNode.hasFocus &&
        !(_debounce?.isActive ?? false) &&
        widget.comment != _controller.text) {
      // Same target updated externally (e.g. solitaire notes appended).
      _controller.text = widget.comment;
    }
  }

  /// Commit the current field before an explicit save or file switch.
  void flush() => _flushDebounce(widget.onCommentChanged);

  void _flushDebounce(ValueChanged<String> handler) {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      // Empty drafts never delete a stored comment, including on disposal.
      if (_controller.text.trim().isNotEmpty) handler(_controller.text);
    }
    _debounce = null;
  }

  @override
  void dispose() {
    _mounted.remove(this);
    _flushDebounce(widget.onCommentChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    _debounce?.cancel();
    _debounce = null;
    setState(() {});
    if (text.trim().isEmpty) return;
    if (widget.commentDebounce == Duration.zero) {
      _debounce = null;
      widget.onCommentChanged(text);
      return;
    }
    _debounce = Timer(widget.commentDebounce, () {
      _debounce = null;
      widget.onCommentChanged(text);
    });
  }

  Future<void> _deleteComment() async {
    if (_confirmingDelete || !_hasComment) return;
    _confirmingDelete = true;
    final target = widget.targetKey;
    _flushDebounce(widget.onCommentChanged);
    // Let the host adopt any just-flushed text before taking the snapshot
    // that the user is about to confirm removing.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || widget.targetKey != target) {
      _confirmingDelete = false;
      return;
    }
    final comment = widget.comment;
    final draft = _controller.text;
    final confirmed = await confirmAction(
      context,
      title: AppLocalizations.of(context).pgnDeleteOneComment,
      message: AppLocalizations.of(
        context,
      ).pgnRemoveCommentOn(widget.moveLabel),
      confirmLabel: AppLocalizations.of(context).delete,
    );
    _confirmingDelete = false;
    if (!mounted ||
        widget.targetKey != target ||
        widget.comment != comment ||
        _controller.text != draft) {
      return;
    }
    if (!confirmed) {
      if (_blankReplacement) setState(() => _controller.text = widget.comment);
      return;
    }
    _debounce?.cancel();
    _debounce = null;
    setState(() => _controller.clear());
    widget.onCommentChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.targetKey != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
        color: colors.surface,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.compact)
            InkWell(
              onTap: () {
                if (mounted) setState(() => _expanded = !_expanded);
              },
              child: SizedBox(
                height: 28,
                child: Row(
                  children: [
                    Icon(Icons.notes, size: 16, color: colors.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _hasComment && !_expanded
                            ? widget.comment.replaceAll('\n', ' ')
                            : l10n.pgnComment,
                        style: AppTypography.secondary(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Tooltip(
                      message: _expanded
                          ? l10n.pgnCollapseComment
                          : l10n.pgnEditComment,
                      child: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Text(
              l10n.pgnComment,
              style: AppTypography.bodyStrong(
                context,
              ).copyWith(color: colors.onSurface),
            ),
          if (!widget.compact || _expanded) ...[
            const SizedBox(height: 8),
            // The glyph strip wraps instead of overflowing: the panel lives in
            // side panels the user can drag down to ~190px, where six glyphs
            // no longer fit on one line.
            Wrap(
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final nag in kMoveNags)
                  GlyphButton(
                    symbol: nag.symbol,
                    name: nag.name,
                    color: nag.color,
                    isActive: widget.nags.contains(nag.id),
                    onTap: enabled && widget.glyphsEnabled
                        ? () {
                            // This action serializes the move immediately;
                            // include its pending prose before saving the glyph.
                            _flushDebounce(widget.onCommentChanged);
                            widget.onToggleNag(nag.id);
                          }
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _blankReplacement
                        ? l10n.pgnCommentKept
                        : l10n.pgnCommentLabel,
                    style: _blankReplacement
                        ? AppTypography.caption(context)
                        : AppTypography.bodyStrong(
                            context,
                          ).copyWith(color: colors.onSurface),
                  ),
                ),
                IconButton(
                  tooltip: l10n.pgnDeleteComment,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: enabled && _hasComment ? _deleteComment : null,
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              enabled: enabled,
              onChanged: _onTextChanged,
              minLines: 2,
              maxLines: 4,
              style: AppTypography.body(context),
              cursorColor: colors.onSurface,
              decoration: InputDecoration(
                isDense: true,
                hintText: enabled ? null : l10n.pgnSelectMoveNotes,
                filled: true,
                fillColor: colors.surfaceContainer,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: colors.onSurface),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: colors.onSurface, width: 2),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: colors.onSurface),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
