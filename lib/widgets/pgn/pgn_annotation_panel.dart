/// Persistent annotation panel shown at the bottom of the PGN viewer while
/// amend mode is active (ChessBase / Lichess-study style): the move the board
/// currently sits on — mainline or sideline — is always the target. Click a
/// move, type in the comment field, toggle glyphs; no extra "edit" click.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../utils/pgn_comment_utils.dart' show kMoveNags;
import 'movetext_primitives.dart' show GlyphButton;

class PgnAnnotationPanel extends StatefulWidget {
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

  const PgnAnnotationPanel({
    super.key,
    required this.targetKey,
    required this.moveLabel,
    required this.nags,
    required this.comment,
    required this.onToggleNag,
    required this.onCommentChanged,
  });

  @override
  State<PgnAnnotationPanel> createState() => _PgnAnnotationPanelState();
}

class _PgnAnnotationPanelState extends State<PgnAnnotationPanel> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnAnnotationPanel');
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.comment);
  }

  @override
  void didUpdateWidget(PgnAnnotationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetKey != oldWidget.targetKey) {
      // New target: flush any pending edit for the old one, then re-seed.
      _flushDebounce(oldWidget.onCommentChanged);
      _controller.text = widget.comment;
    } else if (!_focusNode.hasFocus && widget.comment != _controller.text) {
      // Same target updated externally (e.g. solitaire notes appended).
      _controller.text = widget.comment;
    }
  }

  void _flushDebounce(ValueChanged<String> handler) {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      handler(_controller.text);
    }
    _debounce = null;
  }

  @override
  void dispose() {
    _flushDebounce(widget.onCommentChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _debounce = null;
      widget.onCommentChanged(text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.targetKey != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
        color: theme.colorScheme.surfaceContainerLow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(
                  enabled ? widget.moveLabel : '—',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final nag in kMoveNags)
                GlyphButton(
                  symbol: nag.symbol,
                  name: nag.name,
                  color: nag.color,
                  isActive: widget.nags.contains(nag.id),
                  onTap: enabled ? () => widget.onToggleNag(nag.id) : null,
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
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: enabled
                  ? 'Comment on ${widget.moveLabel}…'
                  : 'Click or play a move to annotate it',
              hintStyle: TextStyle(fontSize: 12, color: Colors.grey[600]),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:
                    BorderSide(color: theme.dividerColor.withValues(alpha: 0.6)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide:
                    BorderSide(color: theme.dividerColor.withValues(alpha: 0.6)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

