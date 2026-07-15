/// Persistent annotation panel shown at the bottom of the PGN viewer while
/// amend mode is active (ChessBase / Lichess-study style): the move the board
/// currently sits on — mainline or sideline — is always the target. Click a
/// move, type in the comment field, toggle glyphs; no extra "edit" click.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/pgn_comment_utils.dart' show kMoveNags;

class PgnAnnotationPanel extends StatefulWidget {
  /// Focuses the comment field of the most recently mounted panel that has a
  /// target move, placing the cursor at the end. Returns false when no such
  /// panel is on screen, so callers can let the key event fall through.
  /// Escape inside the field hands focus back to whoever had it before.
  static bool focusActive() {
    for (final state in _PgnAnnotationPanelState._mounted.reversed) {
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
  /// Mounted panels, oldest first; [PgnAnnotationPanel.focusActive] targets
  /// the newest so a nested/foreground panel wins over a background one.
  static final List<_PgnAnnotationPanelState> _mounted = [];

  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode(debugLabel: 'PgnAnnotationPanel');
  Timer? _debounce;

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
    _mounted.remove(this);
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
              for (final nag in kMoveNags)
                _GlyphButton(
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
                  ? 'Comment on ${widget.moveLabel}…  (C to type, Esc to leave)'
                  : 'Click or play a move to annotate it',
              hintStyle: TextStyle(fontSize: 12, color: Colors.grey[600]),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.6),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlyphButton extends StatelessWidget {
  final String symbol;
  final String name;
  final Color color;
  final bool isActive;
  final VoidCallback? onTap;

  const _GlyphButton({
    required this.symbol,
    required this.name,
    required this.color,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? color.withValues(alpha: 0.2) : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: isActive
                  ? color.withValues(alpha: 0.7)
                  : Colors.grey.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            symbol,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              color: onTap == null
                  ? Colors.grey[700]
                  : (isActive ? color : Colors.grey[400]),
            ),
          ),
        ),
      ),
    );
  }
}
