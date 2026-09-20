import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../ui/theme.dart';
import 'document_session.dart';

/// The note on the move under the cursor, or the chapter's introduction at
/// the start position.
///
/// It shows the words only: the engine's evaluation, its line and the clock
/// are the move's, not the reader's, and the session puts them back when it
/// writes. The field commits when it loses focus and on Ctrl+Enter. Every
/// way of moving the cursor — a click on a move, a piece on the board —
/// takes the focus off the field first, so the words land on the move they
/// were typed under.
class CommentPanel extends StatefulWidget {
  const CommentPanel({super.key, required this.session});

  final DocumentSession session;

  @override
  State<CommentPanel> createState() => _CommentPanelState();
}

class _CommentPanelState extends State<CommentPanel> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// The node the field is editing, and the text it was given for it.
  NodePath? _at;
  String _given = '';

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_follow);
    _focus.addListener(_onFocusChanged);
    _follow();
  }

  @override
  void dispose() {
    widget.session.removeListener(_follow);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  /// Takes the text of the node the cursor is on now, keeping what the user
  /// typed for the one it was on before.
  void _follow() {
    if (!mounted) return;
    final session = widget.session;
    final at = session.chapter == null ? null : session.cursor;
    if (at == _at && _given == _textFor(at)) return;
    if (at != _at) _commit();
    setState(() {
      _at = at;
      _given = _textFor(at);
      _controller.text = _given;
    });
  }

  String _textFor(NodePath? at) =>
      at == null ? '' : displayComment(widget.session.commentAt(at) ?? '');

  void _commit() {
    final at = _at;
    final text = _controller.text;
    if (at == null || text == _given) return;
    _given = text;
    widget.session.setComment(at, text);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Comment', style: text.labelSmall),
          const SizedBox(height: Space.xs),
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _commit,
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _commit,
            },
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              enabled: _at != null,
              minLines: 2,
              maxLines: 4,
              style: text.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: _at?.isRoot ?? true
                    ? 'About this chapter'
                    : 'About this move',
                hintStyle: text.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
