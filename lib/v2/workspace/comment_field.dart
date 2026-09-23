import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../storage/chapter_files.dart' show ChapterRef;
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'document_session.dart';

/// The note on the move under the cursor, or the chapter's introduction at
/// the start position, open for editing.
///
/// It shows the words only: the engine's evaluation, its line and the clock
/// are the move's, not the reader's, and the session puts them back when it
/// writes. The field commits when it loses the focus, on Ctrl+Enter, when
/// the cursor leaves the node it is editing, when the session is about to
/// put up another document or game, and when the field goes away. What it
/// writes goes to that node, the one it was given the words for, and never
/// to wherever the cursor has reached by then, so words typed under one move
/// cannot land on another — nor in another document.
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

  /// The node the field is editing, the document that node is in, and the
  /// text it was given for it.
  NodePath? _at;
  _Document? _in;
  String _given = '';

  /// While the field hands its words to the session. The session answers by
  /// notifying — the note taken, or refused — and that answer must not start
  /// a second commit of the same words, which a refusal would answer again.
  bool _committing = false;

  /// The note follows the cursor and the words on the move it is on.
  @override
  Listenable listenableOf(CommentField widget) => widget.session.anyChange;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    widget.session.leaving.addListener(_commitBeforeLeaving);
    changed();
  }

  /// Words typed for the document this field was showing are written to it
  /// before the field takes up another one.
  @override
  void didUpdateWidget(CommentField old) {
    if (old.session != widget.session) {
      old.session.leaving.removeListener(_commitBeforeLeaving);
      widget.session.leaving.addListener(_commitBeforeLeaving);
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
    widget.session.leaving.removeListener(_commitBeforeLeaving);
    _focus.removeListener(_onFocusChanged);
    _commit();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  /// Another document or game is going up while the words are still in the
  /// field — a puzzle moving on, a download landing — so they go into the
  /// one they were typed for while it is still the session's.
  void _commitBeforeLeaving() => _commit();

  /// Takes the text of the node the cursor is on now, keeping what the user
  /// typed for the one it was on before.
  @override
  void changed() {
    if (_committing) return;
    final session = widget.session;
    final at = session.chapter == null ? null : session.cursor;
    final text = _textFor(at);
    final here = _documentOf(session);
    if (at == _at && here == _in && _shows(text)) return;
    if (at != _at) _commit();
    setState(() {
      _at = at;
      _in = here;
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
    final session = into ?? widget.session;
    final at = _at;
    final text = _controller.text;
    // A path means another move in another document, so words typed for
    // one never go into the next: the session asked for them before it
    // left ([DocumentSession.leaving]).
    if (at == null || text == _given || _documentOf(session) != _in) return;
    _committing = true;
    try {
      session.setComment(at, text);
    } finally {
      _committing = false;
    }
    // Words the session refused are still the user's: until it takes them
    // the field goes on showing them, to be put right, and the strip says
    // why.
    if (displayComment(session.commentAt(at) ?? '') == displayComment(text)) {
      _given = text;
    }
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

/// The document a path of the session's is a path into: the file and, for
/// one shown a game at a time, the game.
typedef _Document = ({ChapterRef? source, int? game});

_Document _documentOf(DocumentSession session) =>
    (source: session.source, game: session.game);
