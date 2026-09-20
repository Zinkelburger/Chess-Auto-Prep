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
/// writes. The field commits when it loses the focus, on Ctrl+Enter, when
/// the cursor leaves the node it is editing, and when the panel goes away.
/// What it writes goes to that node, the one it was given the words for, and
/// never to wherever the cursor has reached by then, so words typed under
/// one move cannot land on another.
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
    // Words typed into the field are the user's whether or not they left it
    // first, so the panel going away writes them like any other commit.
    widget.session.removeListener(_follow);
    _focus.removeListener(_onFocusChanged);
    _commit();
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
    final text = _textFor(at);
    if (at == _at && _shows(text)) return;
    if (at != _at) _commit();
    setState(() {
      _at = at;
      _given = text;
      _controller.text = text;
    });
  }

  /// Whether the field is right for [text], the words the node has now:
  /// either nothing has changed under it, or it holds those words as the
  /// user typed them. Reading a comment back runs its lines together, so a
  /// field rewritten with that would take the newlines and the caret with
  /// it every time a save came back.
  bool _shows(String text) =>
      _given == text || displayComment(_controller.text) == text;

  String _textFor(NodePath? at) =>
      at == null ? '' : displayComment(widget.session.commentAt(at) ?? '');

  void _commit() {
    final at = _at;
    final text = _controller.text;
    if (at == null || text == _given) return;
    _given = text;
    widget.session.setComment(at, text);
  }

  /// The note the file wrote before the move the field is on, if it had one.
  /// It is shown, not edited: it belongs to the line the move introduces and
  /// nothing here decides yet what editing it would mean.
  String get _introduction {
    final at = _at;
    if (at == null) return '';
    return displayComment(widget.session.startingCommentAt(at) ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final introduction = _introduction;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, Space.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (introduction.isNotEmpty) ...[
            Text('Before this move', style: text.labelSmall),
            const SizedBox(height: Space.xs),
            Text(
              introduction,
              style: text.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: Space.s),
          ],
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
