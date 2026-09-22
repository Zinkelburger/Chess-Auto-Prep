import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';

/// The note on the move under the cursor, or the chapter's introduction at
/// the start position, open for editing.
///
/// It shows the words only: the engine's evaluation, its line and the clock
/// are the move's, not the reader's, and the session puts them back when it
/// writes. The field commits when it loses the focus, on Ctrl+Enter, when
/// the cursor leaves the node it is editing, and when the field goes away.
/// What it writes goes to that node, the one it was given the words for, and
/// never to wherever the cursor has reached by then, so words typed under
/// one move cannot land on another.
class CommentField extends StatefulWidget {
  const CommentField({super.key, required this.session});

  final DocumentSession session;

  @override
  State<CommentField> createState() => _CommentFieldState();
}

class _CommentFieldState extends State<CommentField>
    with ListeningState<CommentField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// The node the field is editing, and the text it was given for it.
  NodePath? _at;
  String _given = '';

  /// The note follows the cursor and the words on the move it is on.
  @override
  Listenable listenableOf(CommentField widget) => widget.session.anyChange;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    changed();
  }

  /// Words typed for the document this field was showing are written to it
  /// before the field takes up another one.
  @override
  void didUpdateWidget(CommentField old) {
    if (old.session != widget.session) {
      _commit(old.session);
      _at = null;
    }
    super.didUpdateWidget(old);
  }

  @override
  void dispose() {
    // Words typed into the field are the user's whether or not they left it
    // first, so the field going away writes them like any other commit.
    stopListening();
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
  @override
  void changed() {
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

  void _commit([DocumentSession? into]) {
    final at = _at;
    final text = _controller.text;
    if (at == null || text == _given) return;
    _given = text;
    (into ?? widget.session).setComment(at, text);
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
    return Column(
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
    );
  }
}
